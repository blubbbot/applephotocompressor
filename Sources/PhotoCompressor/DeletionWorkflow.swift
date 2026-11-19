import Foundation
import Photos
import CompressionCore

@MainActor
struct DeletionServices {
    struct Asset: Sendable {
        let id: String
        let modifiedAt: Date?
        let duration: Double
    }

    var fetch: (String) -> Asset?
    var refreshSharing: (String) async -> SharedLibraryObservation?
    var revalidateReplacement: (OperationRecord) async throws -> Date?
    var verifyArchives: (OperationRecord, CancellationFlag) async throws -> Void
    var delete: ([Asset]) async throws -> Void

    static func photos(sharing: SharedLibraryController) -> Self {
        Self(fetch: { id in
            PhotosService.fetch(id).map { Asset(id: $0.localIdentifier, modifiedAt: $0.modificationDate, duration: $0.duration) }
        }, refreshSharing: { id in
            guard let original = PhotosService.fetch(id), let identity = SharedLibraryController.identity(original) else { return nil }
            return await sharing.inspect([identity])[id]
        }, revalidateReplacement: { record in
            try await PhotosService.revalidateChangedReplacement(record, original: PhotosService.fetch(record.sourceID))
        }, verifyArchives: { record, flag in
            try await Task.detached(priority: .utility) { try ArchiveIntegrity.verify(record, cancellation: flag) }.value
        }, delete: { snapshots in
            // PhotoKit needs live assets, so re-fetching here also closes the
            // window after the candidate filter. Any change cancels the batch.
            let assets = try snapshots.map { snapshot in
                guard let asset = PhotosService.fetch(snapshot.id), asset.modificationDate == snapshot.modifiedAt else {
                    throw MediaError.invalid("An original changed or disappeared before deletion. Original retained.")
                }
                return asset
            }
            try await PhotosService.delete(assets)
        })
    }
}

extension AppModel {
    func deletePending(_ ids: Set<UUID>) {
        guard !isBusy, connected, !pending.isEmpty else { return }
        let records = pending.filter { ids.contains($0.id) }
        guard !records.isEmpty else { return }
        isBusy = true
        Task { await deleteReady(records, markReviewed: true); isBusy = false; await reloadHistory() }
    }

    func deleteOriginal(for id: String) {
        let ids = Set(pending.filter { $0.sourceID == id }.map(\.id))
        deletePending(ids)
    }

    func deleteReady(_ records: [OperationRecord], markReviewed: Bool = false, services: DeletionServices? = nil) async {
        guard let journal else { return }
        let services = services ?? .photos(sharing: sharing)
        var candidates: [(OperationRecord, DeletionServices.Asset)] = []
        for record in records {
            if !markReviewed && cancellation.isCancelled { return }
            var verified = record
            do {
                if let observation = await services.refreshSharing(record.sourceID),
                   observation.state == .shared || record.sourceSharedLibrary?.state != .shared {
                    verified.sourceSharedLibrary = observation
                    try await journal.save(verified)
                }
                if let id = record.replacementID, let replacement = services.fetch(id),
                   let expected = record.replacementModifiedAt, replacement.modifiedAt != expected {
                    activity = "Rechecking replacement resources and metadata…"
                    verified.replacementModifiedAt = try await services.revalidateReplacement(verified)
                    try await journal.save(verified)
                }
                guard record.isDeletionCandidate,
                      let original = services.fetch(record.sourceID),
                      let replacementID = record.replacementID, let replacement = services.fetch(replacementID),
                      original.modifiedAt == record.sourceModifiedAt,
                      verified.replacementModifiedAt == nil || replacement.modifiedAt == verified.replacementModifiedAt,
                      record.kind.isPhoto || abs(original.duration - replacement.duration) < 0.25 else {
                    throw MediaError.invalid("An original or replacement changed or disappeared. Original retained.")
                }
                activity = "Verifying archive SHA-256 checksums…"
                let flag = markReviewed ? CancellationFlag() : cancellation
                try await services.verifyArchives(verified, flag)
                candidates.append((verified, original))
            } catch {
                statuses[record.sourceID] = RowStatus(text: error.localizedDescription, failed: true)
                verified.error = error.localizedDescription
                try? await journal.save(verified)
                notice = AppNotice(text: error.localizedDescription)
            }
        }
        // Hashing large archives and replacement checks can take time. Refresh
        // every candidate's Photos snapshot again immediately before deletion.
        candidates = candidates.filter { record, asset in
            let original = services.fetch(asset.id)
            let replacement = record.replacementID.flatMap { services.fetch($0) }
            let unchanged = original != nil && replacement != nil && original?.modifiedAt == record.sourceModifiedAt &&
                (record.replacementModifiedAt == nil || replacement?.modifiedAt == record.replacementModifiedAt)
            if !unchanged { notice = AppNotice(text: "A Photos item changed during archive verification. Its original is retained; review and retry.") }
            return unchanged
        }
        guard !candidates.isEmpty else { return }
        // Revalidation may await a resource download. A stop requested during
        // that await must still prevent automatic deletion of prepared originals.
        guard markReviewed || !cancellation.isCancelled else { return }
        activity = "Confirm original deletion in the macOS Photos dialog…"
        do {
            try await services.delete(candidates.map(\.1))
        } catch {
            for (var record, _) in candidates {
                record.error = "Deletion cancelled or failed: \(error.localizedDescription)"
                try? await journal.save(record)
                statuses[record.sourceID] = RowStatus(text: "Smaller copy imported · original retained")
            }
            notice = AppNotice(text: "Smaller copies are imported and your originals are retained. You can retry original deletion from Review. \(error.localizedDescription)")
            return
        }
        // A journal write failure after Photos succeeds must never be described
        // as a cancelled deletion or overwrite other completed records.
        for (var record, _) in candidates {
            record.stage = .originalDeleted; record.error = nil
            if markReviewed { record.reviewDecision = .accepted }
            do { try await journal.save(record) }
            catch { notice = AppNotice(text: "Photos deleted the original and retained the compressed copy, but the history update could not be saved. Both local archives remain. Reconnect Photos and review this item before continuing. \(error.localizedDescription)") }
            statuses[record.sourceID] = RowStatus(text: record.sourceWasShared ? "Replaced · re-share copy from Review" : "Replaced · original archived locally")
            videos.removeAll { $0.id == record.sourceID }; selected.remove(record.sourceID)
            if focusedID == record.sourceID { player?.pause(); player = nil; focusedID = nil }
        }
    }
}
