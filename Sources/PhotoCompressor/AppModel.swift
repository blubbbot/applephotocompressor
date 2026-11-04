import SwiftUI
import Photos
import AVKit
import CompressionCore

enum VideoSort: String, CaseIterable, Identifiable {
    case largest = "Largest first", savings = "Most savings", newest = "Newest first", longest = "Longest first"
    var id: String { rawValue }
}

struct RowStatus {
    var text: String
    var fraction: Double?
    var failed = false
}

struct AppNotice: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var videos: [LibraryVideo] = []
    @Published var selected = Set<String>()
    @Published var focusedID: String?
    @Published var player: AVPlayer?
    @Published var previewLoading = false
    @Published var previewError: String?
    @Published var previewCompressed = false
    @Published var settings = CompressionSettings() {
        didSet { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "compressionSettings") } }
    }
    @Published var search = ""
    @Published var sort: VideoSort = .largest
    @Published var minimumSize: Int64 = 0
    @Published var hideUnsupported = true
    @Published var hideProcessed = true
    @Published var replaceOriginals = false {
        didSet { UserDefaults.standard.set(replaceOriginals, forKey: "replaceOriginals") }
    }
    @Published var isLoading = false
    @Published var isBusy = false
    @Published var indexingSizes = false
    @Published var connected = false
    @Published var demo = false
    @Published var overallProgress = 0.0
    @Published var activity = ""
    @Published var statuses: [String: RowStatus] = [:]
    @Published var history: [OperationRecord] = []
    @Published var showHistory = false
    @Published var notice: AppNotice?
    @Published var backupDirectory: URL {
        didSet { UserDefaults.standard.set(backupDirectory.path, forKey: "backupDirectory") }
    }
    let journal: OperationJournal?
    private var cancellation = CancellationFlag()
    private var previewTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?

    init() {
        backupDirectory = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "backupDirectory") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Photo Compressor Backups").path)
        let journalURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PhotoCompressor/operations.json")
        do { journal = try OperationJournal(url: journalURL) }
        catch { journal = nil; notice = AppNotice(text: "The operation history could not be read. Compression is disabled to avoid losing recovery information: \(error.localizedDescription)") }
        if let data = UserDefaults.standard.data(forKey: "compressionSettings"), let stored = try? JSONDecoder().decode(CompressionSettings.self, from: data) { settings = stored }
        replaceOriginals = UserDefaults.standard.bool(forKey: "replaceOriginals")
        Task { await reloadHistory() }
        if CommandLine.arguments.contains("--demo") { loadDemo() }
    }

    var focused: LibraryVideo? { videos.first { $0.id == focusedID } }
    var selectedVideos: [LibraryVideo] { videos.filter { selected.contains($0.id) } }
    var pending: [OperationRecord] { history.filter(\.isDeletionCandidate) }
    var selectedOriginalBytes: Int64 { selectedVideos.reduce(0) { $0 + ($1.facts.bytes ?? 0) } }
    var selectedEstimatedBytes: Int64 { selectedVideos.reduce(0) { $0 + plan($1).estimatedBytes } }
    var selectedSavings: Int64 { selectedVideos.reduce(0) { $0 + (plan($1).estimatedSavings ?? 0) } }
    var unknownSelectedSizes: Int { selectedVideos.filter { $0.facts.bytes == nil }.count }
    var processedIDs: Set<String> {
        Set(history.filter { $0.replacementID != nil || $0.stage == .originalDeleted }.map(\.sourceID))
    }
    var visible: [LibraryVideo] {
        let outputs = Set(history.compactMap(\.replacementID))
        return videos.filter {
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) &&
            (!hideUnsupported || $0.unsupportedReason == nil) &&
            (!hideProcessed || (!processedIDs.contains($0.id) && !outputs.contains($0.id))) &&
            (minimumSize == 0 || ($0.facts.bytes ?? 0) >= minimumSize)
        }.sorted { lhs, rhs in
            switch sort {
            case .largest: return (lhs.facts.bytes ?? 0, lhs.facts.duration) > (rhs.facts.bytes ?? 0, rhs.facts.duration)
            case .savings: return (plan(lhs).estimatedSavings ?? 0, lhs.facts.duration) > (plan(rhs).estimatedSavings ?? 0, rhs.facts.duration)
            case .newest: return lhs.date > rhs.date
            case .longest: return lhs.facts.duration > rhs.facts.duration
            }
        }
    }
    func plan(_ video: LibraryVideo) -> CompressionPlan { CompressionPlan(facts: video.facts, settings: settings) }
    func outputRecord(for id: String) -> OperationRecord? {
        history.first {
            $0.sourceID == id && $0.outputBytes != nil && $0.stage != .failed &&
            FileManager.default.fileExists(atPath: $0.outputPath)
        }
    }
    func output(for id: String) -> URL? {
        guard let record = outputRecord(for: id) else { return nil }
        return URL(fileURLWithPath: record.outputPath)
    }

    func photosID(for video: LibraryVideo, compressed: Bool = false) -> String? {
        let record = history.first { $0.sourceID == video.id && $0.replacementID != nil }
        if compressed || record?.stage == .originalDeleted { return record?.replacementID }
        return video.asset?.localIdentifier
    }

    func showInPhotos(id: String) {
        Task {
            do { try await PhotosScript.reveal(id: id) }
            catch { notice = AppNotice(text: error.localizedDescription) }
        }
    }

    func connect() {
        guard !isBusy, !isLoading else { return }
        isLoading = true; activity = "Opening your Photos library…"
        Task {
            do {
                try await PhotosService.authorize()
                videos = await PhotosService.videos()
                connected = true; demo = false; selected.removeAll(); focusedID = nil; player = nil
                await reconcileImportedCopies()
                isLoading = false; activity = "\(videos.count) videos in your library"
                indexingSizes = true
                do {
                    let sizes = try await PhotosScript.sizes()
                    var measured = videos
                    for index in measured.indices { if let size = sizes[measured[index].id] { measured[index].facts.bytes = size } }
                    videos = measured
                } catch {
                    notice = AppNotice(text: "The library is open, but file sizes are unavailable. You can still preview and compress videos; sizes are measured when each original downloads. \(error.localizedDescription)")
                }
                indexingSizes = false
            } catch { isLoading = false; activity = ""; notice = AppNotice(text: error.localizedDescription) }
        }
    }

    func openFiles() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        isLoading = true; activity = "Inspecting video files…"
        Task {
            var loaded: [LibraryVideo] = []
            for url in urls {
                do {
                    let info = try await VideoEncoder.inspect(url)
                    loaded.append(LibraryVideo(id: url.path, name: url.lastPathComponent, asset: nil, fileURL: url, facts: info.facts,
                        date: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(), unsupportedReason: nil))
                } catch { notice = AppNotice(text: "\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            videos = loaded; connected = false; demo = false; replaceOriginals = false
            selected.removeAll(); focusedID = nil; player = nil
            isLoading = false; activity = "\(loaded.count) local videos · originals remain in place"
        }
    }

    func focus(_ video: LibraryVideo) {
        focusedID = video.id; previewCompressed = false; loadPreview()
    }

    func loadPreview() {
        previewTask?.cancel(); player?.pause(); player = nil; previewError = nil
        guard let video = focused else { return }
        previewLoading = true
        let useCompressed = previewCompressed
        previewTask = Task {
            do {
                let item: AVPlayerItem
                if useCompressed, let url = output(for: video.id) { item = AVPlayerItem(url: url) }
                else if let url = video.fileURL { item = AVPlayerItem(url: url) }
                else if let asset = video.asset { item = try await PhotosService.preview(asset) }
                else { throw MediaError.invalid("Sample data. Open video files or connect Photos for playback.") }
                guard !Task.isCancelled else { return }
                player = AVPlayer(playerItem: item); previewLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                previewLoading = false; previewError = error.localizedDescription
            }
        }
    }

    func toggle(_ video: LibraryVideo) {
        guard !isBusy, video.unsupportedReason == nil else { return }
        if selected.contains(video.id) { selected.remove(video.id) } else { selected.insert(video.id) }
    }

    func selectRecommended() {
        selected = Set(visible.filter {
            guard $0.unsupportedReason == nil, let bytes = $0.facts.bytes, bytes > 100_000_000,
                  let saving = plan($0).estimatedSavings else { return false }
            return Double(saving) / Double(bytes) >= settings.minimumSavings
        }.map(\.id))
    }

    func chooseArchive() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Use for backups"
        if panel.runModal() == .OK, let url = panel.url { backupDirectory = url }
    }

    func startBatch() {
        guard !isBusy, !demo, let journal else { return }
        let batch = selectedVideos.filter { $0.unsupportedReason == nil }
        guard !batch.isEmpty else { return }
        let settings = self.settings, replace = replaceOriginals && connected, archive = backupDirectory
        isBusy = true; overallProgress = 0; cancellation = CancellationFlag()
        let flag = cancellation
        batchTask = Task {
            var ready: [OperationRecord] = []
            for (index, video) in batch.enumerated() {
                if flag.isCancelled { break }
                activity = "\(index + 1) of \(batch.count) · \(video.name)"
                overallProgress = Double(index) / Double(batch.count)
                if history.contains(where: { $0.sourceID == video.id && $0.replacementID != nil }) {
                    statuses[video.id] = RowStatus(text: "Existing copy · check History", failed: true); continue
                }
                var record = OperationRecord(sourceID: video.id, sourceName: video.name, backupPath: "", outputPath: "", settings: settings)
                let directory = archive.appendingPathComponent(record.id.uuidString)
                let safeName = URL(fileURLWithPath: video.name).lastPathComponent
                let originalURL = directory.appendingPathComponent(safeName)
                let stem = String(URL(fileURLWithPath: safeName).deletingPathExtension().lastPathComponent.prefix(40))
                let outputURL = directory.appendingPathComponent("\(stem) [\(record.id.uuidString)] compressed.mov")
                record.backupPath = originalURL.path; record.outputPath = outputURL.path
                do {
                    try flag.check()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                    let required = (video.facts.bytes ?? 0) * 2 + plan(video).estimatedBytes + 512_000_000
                    if let capacity, capacity < required { throw MediaError.invalid("The backup disk needs approximately \(DisplayFormat.bytes(required)) free for this video and its smaller copy.") }
                    let original = video.asset.flatMap { PhotosService.fetch($0.localIdentifier) }
                    record.sourceModifiedAt = original?.modificationDate
                    try await journal.save(record)
                    let metadata: ScriptMetadata?
                    if let original {
                        statuses[video.id] = RowStatus(text: "Reading library metadata…")
                        metadata = try await PhotosScript.readMetadata(id: original.localIdentifier)
                        statuses[video.id] = RowStatus(text: "Downloading and archiving…", fraction: 0)
                        try await PhotosService.archive(original, to: originalURL) { progress in
                            Task { @MainActor in self.statuses[video.id] = RowStatus(text: "Downloading and archiving…", fraction: progress) }
                        }
                    } else if let file = video.fileURL {
                        metadata = nil; statuses[video.id] = RowStatus(text: "Archiving original…")
                        try await Task.detached { try FileManager.default.copyItem(at: file, to: originalURL) }.value
                    } else { throw MediaError.invalid("The original is no longer in the library. Refresh and try again.") }
                    try flag.check()
                    let sourceInfo = try await VideoEncoder.inspect(originalURL)
                    if let itemIndex = videos.firstIndex(where: { $0.id == video.id }) {
                        videos[itemIndex].facts = sourceInfo.facts
                        videos[itemIndex].factsAreMeasured = true
                    }
                    record.sourceFacts = sourceInfo.facts
                    record.originalBytes = sourceInfo.facts.bytes; record.stage = .archived
                    try await journal.save(record)
                    statuses[video.id] = RowStatus(text: "Compressing…", fraction: 0)
                    let updates = ProgressThrottle()
                    let outputInfo = try await VideoEncoder.encode(source: originalURL, destination: outputURL, settings: settings, cancellation: flag) { progress in
                        if updates.shouldUpdate(progress) { Task { @MainActor in
                            self.statuses[video.id] = RowStatus(text: progress > 0.98 ? "Verifying every output frame…" : "Compressing…", fraction: progress)
                            self.overallProgress = (Double(index) + progress * 0.85) / Double(batch.count)
                        } }
                    }
                    record.outputBytes = outputInfo.facts.bytes; record.stage = .encoded
                    try await journal.save(record)
                    let measuredPlan = CompressionPlan(facts: sourceInfo.facts, settings: settings)
                    guard measuredPlan.meetsMinimumSavings(originalBytes: record.originalBytes ?? 0, outputBytes: record.outputBytes ?? 0, threshold: settings.minimumSavings) else {
                        record.stage = .keptOriginal; try await journal.save(record)
                        statuses[video.id] = RowStatus(text: "Skipped · below minimum savings")
                        await reloadHistory(); continue
                    }
                    try flag.check()
                    if let original, let metadata {
                        statuses[video.id] = RowStatus(text: "Importing and restoring metadata…")
                        let albums = PhotosService.regularAlbums(containing: original)
                        record.replacementID = try await PhotosService.importVideo(outputURL, original: original, albums: albums)
                        record.stage = .imported; try await journal.save(record)
                        try PhotosService.verifyImport(record.replacementID!, original: original, albums: albums)
                        try await PhotosScript.restoreMetadata(metadata, id: record.replacementID!)
                        record.metadataVerified = true
                        record.stage = .readyToDelete
                        try await journal.save(record)
                        if replace { ready.append(record) }
                    } else {
                        record.stage = .keptOriginal; try await journal.save(record)
                    }
                    let saved = (record.originalBytes ?? 0) - (record.outputBytes ?? 0)
                    statuses[video.id] = RowStatus(text: "Copy ready · \(DisplayFormat.bytes(saved)) smaller")
                    selected.remove(video.id)
                } catch {
                    record.stage = .failed; record.error = error is CancellationError ? "Stopped; original retained." : error.localizedDescription
                    try? await journal.save(record)
                    statuses[video.id] = RowStatus(text: record.error ?? "Failed", failed: true)
                }
                await reloadHistory()
            }
            if !flag.isCancelled, !ready.isEmpty { await deleteReady(ready) }
            overallProgress = 1; isBusy = false
            activity = flag.isCancelled ? "Stopped safely. Ready copies and originals are retained." : "Batch finished. Review results in History."
            await reloadHistory()
        }
    }

    func stop() { cancellation.cancel(); activity = "Stopping safely · the current iCloud download may finish first…" }

    func deletePending(_ ids: Set<UUID>) {
        guard !isBusy, connected, !pending.isEmpty else { return }
        let records = pending.filter { ids.contains($0.id) }
        guard !records.isEmpty else { return }
        isBusy = true
        Task { await deleteReady(records); isBusy = false; await reloadHistory() }
    }

    func deleteOriginal(for id: String) {
        let ids = Set(pending.filter { $0.sourceID == id }.map(\.id))
        deletePending(ids)
    }

    private func deleteReady(_ records: [OperationRecord]) async {
        guard let journal else { return }
        var candidates: [(OperationRecord, PHAsset)] = []
        for record in records {
            do {
                guard record.isDeletionCandidate,
                      let original = PhotosService.fetch(record.sourceID),
                      let replacementID = record.replacementID, let replacement = PhotosService.fetch(replacementID),
                      original.modificationDate == record.sourceModifiedAt,
                      abs(original.duration - replacement.duration) < 0.25 else {
                    throw MediaError.invalid("An original or replacement changed or disappeared. Original retained.")
                }
                let backupSize = try URL(fileURLWithPath: record.backupPath).resourceValues(forKeys: [.fileSizeKey]).fileSize
                let outputSize = try URL(fileURLWithPath: record.outputPath).resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard backupSize.map(Int64.init) == record.originalBytes, outputSize.map(Int64.init) == record.outputBytes else {
                    throw MediaError.invalid("The local archive or output is missing or changed. Original retained.")
                }
                candidates.append((record, original))
            } catch { statuses[record.sourceID] = RowStatus(text: error.localizedDescription, failed: true) }
        }
        guard !candidates.isEmpty else { return }
        activity = "Confirm original deletion in the macOS Photos dialog…"
        do {
            try await PhotosService.delete(candidates.map(\.1))
            for (var record, _) in candidates {
                record.stage = .originalDeleted; record.error = nil
                try await journal.save(record)
                statuses[record.sourceID] = RowStatus(text: "Replaced · original archived locally")
            }
        } catch {
            for (var record, _) in candidates {
                record.error = "Deletion cancelled or failed: \(error.localizedDescription)"
                try? await journal.save(record)
                statuses[record.sourceID] = RowStatus(text: "Smaller copy imported · original retained")
            }
            notice = AppNotice(text: "Smaller copies are imported and your originals are retained. You can retry original deletion from History. \(error.localizedDescription)")
        }
    }

    func reloadHistory() async { if let journal { history = await journal.all() } }

    private func reconcileImportedCopies() async {
        guard let journal else { return }
        await reloadHistory()
        for var record in history where record.replacementID == nil && record.outputBytes != nil {
            let name = URL(fileURLWithPath: record.outputPath).lastPathComponent
            let matches = videos.filter { $0.name == name && $0.id != record.sourceID }
            // Recover an import completed just before a crash, without granting deletion eligibility.
            if matches.count == 1 {
                record.replacementID = matches[0].id; record.stage = .imported
                record.error = "Recovered an imported copy after interruption. The original is retained; review the copy and metadata before making further changes."
                try? await journal.save(record)
            }
        }
        await reloadHistory()
    }

    func loadDemo() {
        guard !isBusy else { return }
        demo = true; connected = false; selected.removeAll(); player = nil; focusedID = nil
        let samples: [(String, Int, Int, Double, Int64, Bool)] = [
            ("A weekend by the sea.mov", 3840, 2160, 182, 1_480_000_000, true),
            ("Birthday candles.mov", 3840, 2160, 94, 810_000_000, true),
            ("The long way home.mov", 3840, 2160, 251, 1_920_000_000, false),
            ("Coffee in the garden.mov", 1920, 1080, 48, 168_000_000, false),
            ("First snow.mov", 2160, 3840, 63, 540_000_000, true),
            ("Sunday at the park.mov", 1920, 1080, 128, 420_000_000, false)
        ]
        videos = samples.enumerated().map { index, sample in
            LibraryVideo(id: "demo-\(index)", name: sample.0, asset: nil, fileURL: nil,
                facts: VideoFacts(width: sample.1, height: sample.2, duration: sample.3, bytes: sample.4, isHDR: sample.5),
                date: Date().addingTimeInterval(Double(-index) * 86400 * 28), unsupportedReason: nil, isDemo: true)
        }
        activity = "Sample library · illustrative sizes"
        selected = Set(videos.prefix(2).map(\.id))
        if let first = videos.first { focusedID = first.id }
    }
}

private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast
    func shouldUpdate(_ progress: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(lastUpdate) > 0.15 || progress >= 1 else { return false }
        lastUpdate = Date(); return true
    }
}
