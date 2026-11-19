import Foundation
import Photos
import CompressionCore

extension AppModel {
    var resumableRecords: [OperationRecord] {
        history.filter(\.canResume).sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt }
    }

    func dismissInterrupted(_ record: OperationRecord) {
        guard !isBusy, let journal, record.canDismissResume else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                var dismissed = record; dismissed.resumeDismissed = true
                try await journal.save(dismissed)
                await reloadHistory()
            } catch { notice = AppNotice(text: error.localizedDescription) }
        }
    }

    func canResume(_ record: OperationRecord) -> Bool {
        !isBusy && !isInspecting && !isLoading && !indexingSizes && !demo && record.canResume &&
        (!record.isPhotosOperation || connected)
    }

    func resumeInterrupted(_ record: OperationRecord? = nil) {
        let records = record.map { [$0] } ?? resumableRecords
        guard !records.isEmpty, records.allSatisfy({ canResume($0) }) else { return }
        // Resuming never automatically deletes originals, even if the original
        // batch requested replacement. The finished copies go through Review.
        runBatch(records, replace: false)
    }

    func startBatch() {
        guard !isBusy, !isInspecting, !isLoading, !indexingSizes, !demo, journal != nil else { return }
        let batch = selectedVideos.filter { $0.unsupportedReason == nil }
        guard !batch.isEmpty else { return }
        var records: [OperationRecord] = []
        for video in batch {
            if let interrupted = history.first(where: { $0.sourceID == video.id && $0.canResume }) {
                guard interrupted.settings == settings, !video.kind.isPhoto || interrupted.photoSettings == photoSettings else {
                    notice = AppNotice(text: "An interrupted operation for \(video.name) uses different settings. Resume or retry it from History with its saved settings before starting another compression.")
                    showHistory = true
                    return
                }
                records.append(interrupted)
                continue
            }
            var record = OperationRecord(sourceID: video.id, sourceName: video.name, backupPath: "", outputPath: "", settings: settings)
            record.mediaKind = video.kind
            if video.kind.isPhoto { record.sourceIsPanorama = video.isPanorama; record.photoSettings = photoSettings }
            let directory = backupDirectory.appendingPathComponent(record.id.uuidString)
            let safeName = URL(fileURLWithPath: video.name).lastPathComponent
            record.backupPath = directory.appendingPathComponent(safeName).path
            let stem = String(URL(fileURLWithPath: safeName).deletingPathExtension().lastPathComponent.prefix(40))
            record.outputPath = directory.appendingPathComponent("\(stem) [\(record.id.uuidString)] compressed.\(video.kind.isPhoto ? "heic" : "mov")").path
            records.append(record)
        }
        // Any reused operation is review-first, just like an explicit resume.
        let resuming = records.contains { record in history.contains { $0.id == record.id } }
        runBatch(records, replace: !resuming && replaceOriginals && connected)
    }

    private func runBatch(_ records: [OperationRecord], replace: Bool) {
        guard let journal else { return }
        isBusy = true; overallProgress = 0; cancellation = CancellationFlag(); batchSummary = nil
        let flag = cancellation
        batchTask = Task {
            let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Compressing media and preserving original archives")
            defer {
                ProcessInfo.processInfo.endActivity(awake)
                isBusy = false; refreshArchiveSpace()
            }
            var summary = BatchSummary(total: records.count)
            let operationIDs = Set(records.map(\.id))
            var ready: [OperationRecord] = []
            do {
                try await journal.save(records)
                await reloadHistory()
            } catch {
                notice = AppNotice(text: "The batch could not be queued safely. No media was changed. \(error.localizedDescription)")
                return
            }
            for (index, saved) in records.enumerated() {
                if flag.isCancelled { break }
                var record = saved
                activity = "\(index + 1) of \(records.count) · \(record.sourceName)"
                overallProgress = Double(index) / Double(records.count)
                if history.contains(where: { $0.id != record.id && $0.sourceID == record.sourceID && $0.replacementID != nil && $0.stage != .reverted }) {
                    record.stage = .keptOriginal
                    record.error = "An existing copy is available in Review. No duplicate was imported."
                    do { try await journal.save(record) }
                    catch { notice = AppNotice(text: error.localizedDescription) }
                    statuses[record.sourceID] = RowStatus(text: "Existing copy · check Review")
                    summary.skipped += 1; selected.remove(record.sourceID)
                    await reloadHistory(); continue
                }
                do {
                    let completed = try await processBatchRecord(&record, index: index, count: records.count, cancellation: flag)
                    if completed {
                        let savedBytes = max(0, (record.originalBytes ?? 0) - (record.outputBytes ?? 0))
                        summary.completed += 1; summary.savedBytes += savedBytes
                        statuses[record.sourceID] = RowStatus(text: "Copy ready · \(DisplayFormat.bytes(savedBytes)) smaller")
                        selected.remove(record.sourceID)
                        if replace && record.isDeletionCandidate { ready.append(record) }
                    } else { summary.skipped += 1 }
                } catch {
                    if error is CancellationError { summary.interrupted += 1 } else { summary.failed += 1 }
                    record.stage = .failed
                    record.error = error is CancellationError ? "Stopped; original retained. Resume from History." : error.localizedDescription
                    do { try await journal.save(record) }
                    catch { notice = AppNotice(text: "Recovery information could not be saved. Keep the archive folder and reconnect its disk before retrying. \(error.localizedDescription)") }
                    statuses[record.sourceID] = RowStatus(text: record.error ?? "Failed", failed: true)
                }
                await reloadHistory()
            }
            if !flag.isCancelled, !ready.isEmpty { await deleteReady(ready) }
            overallProgress = 1
            activity = flag.isCancelled ? "Stopped safely. Resume interrupted work from History." : "Batch finished. Open Review to compare your copies."
            await reloadHistory()
            refreshSharing(force: true)
            summary.originalsDeleted = history.filter { operationIDs.contains($0.id) && $0.stage == .originalDeleted }.count
            summary.stopped = flag.isCancelled
            batchSummary = summary
        }
    }

    private func processBatchRecord(_ record: inout OperationRecord, index: Int, count: Int, cancellation flag: CancellationFlag) async throws -> Bool {
        guard let journal else { throw MediaError.invalid("The operation journal is unavailable.") }
        try flag.check()
        let source = URL(fileURLWithPath: record.backupPath), output = URL(fileURLWithPath: record.outputPath)
        let directory = source.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original: PHAsset?
        if record.isPhotosOperation {
            guard connected, let asset = PhotosService.fetch(record.sourceID) else { throw MediaError.invalid("Connect the original Photos library before resuming this item. Its original must still be present.") }
            if let reason = PhotosService.protectionReason(for: asset) { throw MediaError.invalid(reason) }
            original = asset
            // Older releases did not save the pre-import checkpoint. Look for
            // their unique resource name before replacing any unverified files.
            if record.originalFingerprint == nil, record.replacementID == nil, record.outputBytes != nil,
               let recovered = try await PhotosService.asset(named: output.lastPathComponent, photos: record.kind.isPhoto) {
                record.replacementID = recovered.localIdentifier; record.importAttempted = true
                try await journal.save(record)
            }
            if record.originalFingerprint != nil || record.importAttempted == true || record.replacementID != nil {
                guard asset.modificationDate == record.sourceModifiedAt else { throw MediaError.invalid("The original changed since this operation started. Its archived files are retained; review it in Photos before continuing.") }
            } else { record.sourceModifiedAt = asset.modificationDate }
        } else { original = nil }

        if record.originalFingerprint != nil {
            // A completed output verifies the full manifest below; avoid hashing
            // the large original twice when resuming an encoded checkpoint.
            if record.outputFingerprint == nil {
                statuses[record.sourceID] = RowStatus(text: "Verifying archived original…")
                let snapshot = record
                try await Task.detached { try BatchRecovery.verifyReusableOriginal(snapshot, cancellation: flag) }.value
            }
        } else {
            guard record.importAttempted != true, record.replacementID == nil, record.outputFingerprint == nil else {
                throw MediaError.invalid("This older operation has no original checksum. Keep its original and archives; automatic recovery cannot establish their integrity.")
            }
            let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            let item = videos.first { $0.id == record.sourceID }
            let estimated = item?.facts.bytes ?? record.originalBytes ?? 0
            let outputEstimate = item.map { LibraryListIndex.estimatedBytes($0, settings: record.settings, photoSettings: record.photoSettings ?? .init()) } ?? estimated
            let required = estimated * 2 + max(estimated, outputEstimate) + 512_000_000
            if let capacity, capacity < required { throw MediaError.invalid("The archive disk needs approximately \(DisplayFormat.bytes(required)) free for this item and its smaller copy.") }
            if let original {
                record.sourceTextMetadata = try await PhotosScript.readMetadata(id: original.localIdentifier)
                if let identity = SharedLibraryController.identity(original) {
                    let observation = await sharing.inspect([identity])[original.localIdentifier]
                    record.sourceSharedLibrary = observation?.state == .unknown ? (sharing.knownSharedOriginal(original.localIdentifier) ?? observation) : observation
                }
            }
            try await journal.save(record)
            try BatchRecovery.preserveUnverifiedFile(at: source)
            statuses[record.sourceID] = RowStatus(text: original == nil ? "Archiving original…" : "Downloading and archiving…", fraction: 0)
            if let original {
                let id = record.sourceID
                try await PhotosService.archive(original, to: source) { progress in
                    Task { @MainActor in self.statuses[id] = RowStatus(text: "Downloading and archiving…", fraction: progress) }
                }
            } else {
                let file = URL(fileURLWithPath: record.sourceID)
                try await Task.detached { try FileManager.default.copyItem(at: file, to: source) }.value
            }
            record.originalFingerprint = try await Task.detached { try ArchiveIntegrity.fingerprint(source, cancellation: flag) }.value
            record.originalBytes = record.originalFingerprint!.bytes + (record.pairedVideoBytes ?? 0)
            try await journal.save(record)
        }
        try flag.check()

        if record.outputFingerprint != nil {
            statuses[record.sourceID] = RowStatus(text: "Verifying reusable compressed copy…")
            let snapshot = record
            try await Task.detached { try ArchiveIntegrity.verify(snapshot, cancellation: flag) }.value
        } else {
            guard record.importAttempted != true, record.replacementID == nil else {
                throw MediaError.invalid("The previously imported output has no recorded checksum. Keep both Photos items and inspect this older operation manually.")
            }
            try BatchRecovery.preserveUnverifiedFile(at: output)
            if record.kind.isPhoto {
                guard let photoSettings = record.photoSettings else { throw MediaError.invalid("This photo operation has no saved settings.") }
                try await encodePhoto(original: original, source: source, output: output, record: &record, settings: photoSettings, cancellation: flag)
            } else {
                let sourceInfo = try await VideoEncoder.inspect(source)
                record.sourceFacts = sourceInfo.facts; record.originalBytes = sourceInfo.facts.bytes; record.stage = .archived
                updateMeasuredFacts(record)
                try await journal.save(record)
                let plan = CompressionPlan(facts: sourceInfo.facts, settings: record.settings, audioTracks: sourceInfo.audioTracks, audioBitrate: sourceInfo.audioBitrate)
                try requireOutputSpace(at: directory, estimatedBytes: plan.estimatedBytes)
                statuses[record.sourceID] = RowStatus(text: "Compressing…", fraction: 0)
                let updates = ProgressThrottle(), id = record.sourceID
                let outputInfo = try await VideoEncoder.encode(source: source, destination: output, settings: record.settings, cancellation: flag) { progress in
                    if updates.shouldUpdate(progress) { Task { @MainActor in
                        self.statuses[id] = RowStatus(text: progress > 0.98 ? "Verifying every output frame…" : "Compressing…", fraction: progress)
                        self.overallProgress = (Double(index) + progress * 0.85) / Double(count)
                    } }
                }
                record.outputBytes = outputInfo.facts.bytes
            }
            record.outputFingerprint = try await Task.detached { try ArchiveIntegrity.fingerprint(output, cancellation: flag) }.value
            record.stage = .encoded
            try await journal.save(record)
        }
        updateMeasuredFacts(record)
        let before = record.originalBytes ?? 0, after = record.outputBytes ?? .max
        let threshold = record.photoSettings?.minimumSavings ?? record.settings.minimumSavings
        guard before > 0, after > 0, after < before, Double(before - after) / Double(before) >= threshold else {
            record.stage = .keptOriginal; record.error = nil
            try await journal.save(record)
            statuses[record.sourceID] = RowStatus(text: "Skipped · below minimum savings")
            return false
        }
        try flag.check()
        if let original {
            try await finishImport(&record, original: original, cancellation: flag)
        } else {
            record.stage = .keptOriginal; record.error = nil
            try await journal.save(record)
        }
        return true
    }

    func updateMeasuredFacts(_ record: OperationRecord) {
        guard let facts = record.sourceFacts, let index = videos.firstIndex(where: { $0.id == record.sourceID }) else { return }
        videos[index].facts = facts; videos[index].factsAreMeasured = true
        videos[index].pairedVideoBytes = record.pairedVideoBytes
        if let photo = record.photoFacts { videos[index].photoFormat = photo.format }
    }

    func requireOutputSpace(at directory: URL, estimatedBytes: Int64) throws {
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let required = estimatedBytes + 512_000_000
        if let capacity, capacity < required { throw MediaError.invalid("The archive disk needs approximately \(DisplayFormat.bytes(required)) free to finish this copy. The archived original is retained; reconnect or free space on its disk and retry.") }
    }

    private func finishImport(_ record: inout OperationRecord, original: PHAsset, cancellation flag: CancellationFlag) async throws {
        guard let journal, let metadata = record.sourceTextMetadata else { throw MediaError.invalid("The saved library metadata is unavailable. Original retained.") }
        let albums = PhotosService.regularAlbums(containing: original)
        let snapshot = record
        try flag.check()
        statuses[record.sourceID] = RowStatus(text: "Recovering import and restoring metadata…")
        let existing = try await ImportRecovery.ensureImported(&record, findExisting: { name in
            try flag.check()
            return try await PhotosService.asset(named: name, photos: snapshot.kind.isPhoto)?.localIdentifier
        }, create: {
            try flag.check()
            let id = try await PhotosService.importVideo(URL(fileURLWithPath: snapshot.outputPath), original: original, albums: albums,
                pairedVideo: snapshot.outputIsLivePhoto ? snapshot.pairedVideoPath.map { URL(fileURLWithPath: $0) } : nil)
            return ImportedCopy(id: id, modifiedAt: PhotosService.fetch(id)?.modificationDate)
        }, persist: { try await journal.save($0) })
        guard let id = record.replacementID, let replacement = PhotosService.fetch(id) else { throw MediaError.invalid("The imported copy is missing. No duplicate was imported. Inspect this item in Photos before continuing.") }
        record.stage = .imported
        try await journal.save(record)
        try flag.check()
        if existing {
            if let expected = record.replacementModifiedAt, replacement.modificationDate != expected {
                record.replacementModifiedAt = try await PhotosService.revalidateChangedReplacement(record, original: original)
            } else {
                try await PhotosService.verifyReplacementResources(record, replacement: replacement)
            }
        }
        try PhotosService.verifyImport(id, original: original, albums: albums, expectedLive: record.kind.isPhoto ? record.outputIsLivePhoto : nil)
        if let photo = record.outputPhotoFacts, replacement.pixelWidth != photo.width || replacement.pixelHeight != photo.height {
            throw MediaError.invalid("The imported photo's dimensions were not verified. Original retained.")
        }
        try await PhotosScript.restoreMetadata(metadata, id: id)
        guard PhotosService.fetch(original.localIdentifier)?.modificationDate == record.sourceModifiedAt else { throw MediaError.invalid("The original changed during compression. Both copies are retained.") }
        record.metadataVerified = true
        record.replacementModifiedAt = PhotosService.fetch(id)?.modificationDate
        record.stage = .readyToDelete; record.error = nil
        try await journal.save(record)
    }
}
