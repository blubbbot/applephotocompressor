import SwiftUI
import Photos
import AVKit
import CompressionCore
import Combine

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

enum MediaMode: String, CaseIterable, Identifiable {
    case videos = "Videos", photos = "Photos"
    var id: Self { self }
}

@MainActor
final class AppModel: ObservableObject {
    let sharing = SharedLibraryController()
    private var sharingChanges: AnyCancellable?
    @Published var videos: [LibraryVideo] = [] { didSet { deferListReordering() } }
    @Published private(set) var mediaMode: MediaMode = .videos
    @Published var photoSettings = PhotoCompressionSettings() {
        didSet {
            if let data = try? JSONEncoder().encode(photoSettings) { UserDefaults.standard.set(data, forKey: "photoCompressionSettings") }
            updateListOrderNow()
        }
    }
    @Published var sharedLibraryReplacementPrompt = false
    private var sharedLibraryReplacementAcknowledged = false
    @Published var selected = Set<String>() { didSet { refreshArchiveSpace() } }
    @Published var focusedID: String?
    @Published var player: AVPlayer?
    @Published var previewLoading = false
    @Published var previewError: String?
    @Published var previewCompressed = false
    @Published var settings = CompressionSettings() {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "compressionSettings") }
            updateListOrderNow()
        }
    }
    @Published var search = "" { didSet { UserDefaults.standard.set(search, forKey: mediaMode == .videos ? "librarySearch" : "photoLibrarySearch") } }
    @Published var sort: VideoSort = .largest { didSet { UserDefaults.standard.set(sort.rawValue, forKey: mediaMode == .videos ? "librarySort" : "photoLibrarySort"); updateListOrderNow() } }
    @Published private var listOrder = StableListOrder<String>()
    @Published var minimumSize: Int64 = 0 { didSet { UserDefaults.standard.set(minimumSize, forKey: mediaMode == .videos ? "libraryMinimumSize" : "photoLibraryMinimumSize") } }
    @Published var hideUnsupported = true { didSet { UserDefaults.standard.set(hideUnsupported, forKey: "hideUnsupported") } }
    @Published var hideProcessed = true { didSet { UserDefaults.standard.set(hideProcessed, forKey: "hideProcessed") } }
    @Published var replaceOriginals = false {
        didSet { UserDefaults.standard.set(replaceOriginals, forKey: mediaMode == .videos ? "replaceOriginals" : "photoReplaceOriginals") }
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
    @Published var section: AppSection = .library {
        didSet { if section == .review { player?.pause() } }
    }
    @Published var reviewFocusedID: UUID?
    @Published var reviewPreviewExpanded = false
    @Published var reviewPrompt: ReviewPrompt?
    @Published var isReviewing = false
    @Published var notice: AppNotice?
    @Published var inspections: [String: InspectionStatus] = [:]
    @Published var inspectionPrompt: InspectionPrompt?
    @Published var batchSummary: BatchSummary?
    @Published var archiveSpace: ArchiveSpaceSnapshot?
    @Published var backupDirectory: URL {
        didSet { UserDefaults.standard.set(backupDirectory.path, forKey: "backupDirectory"); refreshArchiveSpace() }
    }
    let journal: OperationJournal?
    private var cancellation = CancellationFlag()
    private var previewTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var inspectionTasks: [String: Task<Void, Never>] = [:]
    private var inspectionIDs: [String: UUID] = [:]
    private var archiveSpaceTask: Task<Void, Never>?
    private var reorderTask: Task<Void, Never>?
    private var previewPosition = CMTime.zero
    private var previewShouldResume = false
    private var previewMuted = false

    init() {
        backupDirectory = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "backupDirectory") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Photo Compressor Backups").path)
        let journalURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PhotoCompressor/operations.json")
        do { journal = try OperationJournal(url: journalURL) }
        catch { journal = nil; notice = AppNotice(text: "The operation history could not be read. Compression is disabled to avoid losing recovery information: \(error.localizedDescription)") }
        if let data = UserDefaults.standard.data(forKey: "compressionSettings"), let stored = try? JSONDecoder().decode(CompressionSettings.self, from: data) { settings = stored }
        if let data = UserDefaults.standard.data(forKey: "photoCompressionSettings"), let stored = try? JSONDecoder().decode(PhotoCompressionSettings.self, from: data) { photoSettings = stored }
        if !UserDefaults.standard.bool(forKey: "originalFrameRateDefaultV1") {
            settings.frameRate = .original
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "compressionSettings") }
            UserDefaults.standard.set(true, forKey: "originalFrameRateDefaultV1")
        }
        search = UserDefaults.standard.string(forKey: "librarySearch") ?? ""
        sort = UserDefaults.standard.string(forKey: "librarySort").flatMap(VideoSort.init(rawValue:)) ?? .largest
        minimumSize = max(0, (UserDefaults.standard.object(forKey: "libraryMinimumSize") as? NSNumber)?.int64Value ?? 0)
        hideUnsupported = UserDefaults.standard.object(forKey: "hideUnsupported") as? Bool ?? true
        hideProcessed = UserDefaults.standard.object(forKey: "hideProcessed") as? Bool ?? true
        replaceOriginals = UserDefaults.standard.bool(forKey: "replaceOriginals")
        sharingChanges = sharing.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        Task { await reloadHistory(); refreshArchiveSpace() }
        if CommandLine.arguments.contains("--demo") { loadDemo() }
    }

    var focused: LibraryVideo? { videos.first { $0.id == focusedID } }
    var selectedVideos: [LibraryVideo] { videos.filter { selected.contains($0.id) } }
    var pending: [OperationRecord] { history.filter(\.isDeletionCandidate) }
    var reviewRecords: [OperationRecord] { history.filter { $0.hasReviewableCopy && $0.kind.isPhoto == (mediaMode == .photos) } }
    var awaitingReview: [OperationRecord] { reviewRecords.filter(\.needsReview) }
    var selectedOriginalBytes: Int64 { selectedVideos.reduce(0) { $0 + ($1.facts.bytes ?? 0) } }
    var selectedEstimatedBytes: Int64 { selectedVideos.reduce(0) { $0 + estimatedBytes($1) } }
    var selectedSavings: Int64 { selectedVideos.reduce(0) { $0 + (estimatedSavings($1) ?? 0) } }
    var unknownSelectedSizes: Int { selectedVideos.filter { $0.facts.bytes == nil }.count }
    var isInspecting: Bool { inspections.values.contains(where: \.isWorking) }
    var slowMotionCount: Int { videos.filter(\.isSlowMotion).count }
    var estimatedArchiveBytes: Int64 {
        guard !selected.isEmpty else { return 0 }
        let largest = selectedVideos.compactMap(\.facts.bytes).max() ?? 0
        return selectedOriginalBytes + selectedEstimatedBytes + largest + 512_000_000
    }
    var archiveMayBeTooSmall: Bool {
        guard let available = archiveSpace?.availableBytes, !selected.isEmpty else { return false }
        return available < estimatedArchiveBytes
    }
    var processedIDs: Set<String> {
        Set(history.filter { $0.stage != .reverted && ($0.replacementID != nil || $0.stage == .originalDeleted) }.map(\.sourceID))
    }
    var visible: [LibraryVideo] {
        let outputs = Set(history.filter { $0.stage != .reverted }.compactMap(\.replacementID))
        let ranks = Dictionary(uniqueKeysWithValues: listOrder.ids.enumerated().map { ($0.element, $0.offset) })
        return videos.filter {
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) &&
            (!hideUnsupported || $0.unsupportedReason == nil) &&
            (!hideProcessed || (!processedIDs.contains($0.id) && !outputs.contains($0.id))) &&
            (minimumSize == 0 || ($0.facts.bytes ?? 0) >= minimumSize)
        }.sorted { (ranks[$0.id] ?? .max) < (ranks[$1.id] ?? .max) }
    }

    var listOrderPending: Bool { listOrder.pending != nil }

    private var freshlySortedIDs: [String] {
        videos.sorted { lhs, rhs in
            let left: Double, right: Double
            switch sort {
            case .largest: left = Double(lhs.facts.bytes ?? 0); right = Double(rhs.facts.bytes ?? 0)
            case .savings: left = Double(estimatedSavings(lhs) ?? 0); right = Double(estimatedSavings(rhs) ?? 0)
            case .newest: left = lhs.date.timeIntervalSinceReferenceDate; right = rhs.date.timeIntervalSinceReferenceDate
            case .longest: left = lhs.facts.duration; right = rhs.facts.duration
            }
            if left != right { return left > right }
            return lhs.id < rhs.id
        }.map(\.id)
    }

    private func deferListReordering() {
        listOrder.propose(freshlySortedIDs)
        scheduleListReordering()
    }

    private func scheduleListReordering() {
        reorderTask?.cancel()
        guard listOrderPending else { return }
        reorderTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            listOrder.commit()
        }
    }

    func updateListOrderNow() {
        reorderTask?.cancel(); listOrder.apply(freshlySortedIDs)
    }
    func plan(_ video: LibraryVideo) -> CompressionPlan { CompressionPlan(facts: video.facts, settings: settings) }
    func estimatedBytes(_ video: LibraryVideo) -> Int64 {
        guard video.kind.isPhoto else { return plan(video).estimatedBytes }
        let size = video.facts.bytes ?? Int64(video.facts.width * video.facts.height / 3)
        let (width, height) = PhotoEncoder.dimensions(width: video.facts.width, height: video.facts.height, resolution: photoSettings.resolution)
        let ratio = Double(width * height) / Double(max(1, video.facts.width * video.facts.height))
        // A deliberately rough planning estimate. Live motion is not inspected
        // or downloaded here; only the finished resource totals determine saving.
        let baseFraction = video.photoFormat == "public.heic" ? 0.9 : 0.65
        let fraction = video.kind == .livePhoto && !photoSettings.convertLiveToStill ? 0.9 : min(0.98, max(0.1, baseFraction * photoSettings.quality / 0.8 * ratio))
        return Int64(Double(size) * fraction)
    }
    func estimatedSavings(_ video: LibraryVideo) -> Int64? { video.facts.bytes.map { max(0, $0 - estimatedBytes(video)) } }

    func switchMediaMode(_ mode: MediaMode) {
        guard mode != mediaMode, !isBusy, !isLoading, !indexingSizes else { return }
        clearInspections(); player?.pause(); player = nil; selected.removeAll(); focusedID = nil; reviewFocusedID = nil
        mediaMode = mode
        search = UserDefaults.standard.string(forKey: mode == .videos ? "librarySearch" : "photoLibrarySearch") ?? ""
        minimumSize = max(0, (UserDefaults.standard.object(forKey: mode == .videos ? "libraryMinimumSize" : "photoLibraryMinimumSize") as? NSNumber)?.int64Value ?? 0)
        sort = UserDefaults.standard.string(forKey: mode == .videos ? "librarySort" : "photoLibrarySort").flatMap(VideoSort.init(rawValue:)) ?? .largest
        replaceOriginals = UserDefaults.standard.bool(forKey: mode == .videos ? "replaceOriginals" : "photoReplaceOriginals")
        if mode == .photos && sort == .longest { sort = .largest }
        if connected { connect() }
        else { videos = []; demo = false }
    }
    func outputRecord(for id: String) -> OperationRecord? {
        history.first {
            $0.sourceID == id && $0.outputBytes != nil && $0.stage != .failed && $0.stage != .reverted &&
            FileManager.default.fileExists(atPath: $0.outputPath)
        }
    }
    func output(for id: String) -> URL? {
        guard let record = outputRecord(for: id) else { return nil }
        return URL(fileURLWithPath: record.outputPath)
    }

    func photosID(for video: LibraryVideo, compressed: Bool = false) -> String? {
        let record = history.first { $0.sourceID == video.id && $0.replacementID != nil && $0.stage != .reverted }
        if compressed || record?.stage == .originalDeleted { return record?.replacementID }
        return video.asset?.localIdentifier
    }

    func showInPhotos(id: String) {
        Task {
            do { try await PhotosScript.reveal(id: id) }
            catch { notice = AppNotice(text: error.localizedDescription) }
        }
    }

    func refreshArchiveSpace() {
        archiveSpaceTask?.cancel()
        let directory = backupDirectory
        archiveSpaceTask = Task {
            let snapshot = await Task.detached(priority: .utility) { ArchiveSpaceSnapshot.read(at: directory) }.value
            guard !Task.isCancelled, backupDirectory == directory else { return }
            archiveSpace = snapshot
        }
    }

    func clearSearchAndSizeFilters() { search = ""; minimumSize = 0 }

    func requestInspection(_ video: LibraryVideo) {
        if focusedID != video.id { focus(video, inspectLocally: false) }
        inspect(video, allowNetwork: false, promptIfUnavailable: true)
    }

    func confirmInspection(_ prompt: InspectionPrompt) {
        inspectionPrompt = nil
        guard let video = videos.first(where: { $0.id == prompt.id }) else { return }
        if focusedID != video.id { focus(video, inspectLocally: false) }
        inspect(video, allowNetwork: true)
    }

    func cancelInspection(id: String) {
        inspectionIDs[id] = nil
        inspectionTasks.removeValue(forKey: id)?.cancel()
        inspections[id] = nil
    }

    private func inspect(_ video: LibraryVideo, allowNetwork: Bool, promptIfUnavailable: Bool = false) {
        guard !isBusy, !video.kind.isPhoto, !video.isDemo, !video.hasInspectedFacts, video.unsupportedReason == nil,
              let asset = video.asset, inspections[video.id]?.isWorking != true else { return }
        let token = UUID(), modifiedAt = asset.modificationDate
        inspectionIDs[video.id] = token
        inspections[video.id] = allowNetwork ? .downloading(0) : .checking
        inspectionTasks[video.id] = Task {
            defer {
                if inspectionIDs[video.id] == token {
                    inspectionTasks[video.id] = nil; inspectionIDs[video.id] = nil
                }
                refreshArchiveSpace()
            }
            do {
                let facts = try await PhotosService.inspectOriginal(asset, allowNetwork: allowNetwork) { fraction in
                    guard allowNetwork else { return }
                    Task { @MainActor in
                        guard self.inspectionIDs[video.id] == token else { return }
                        self.inspections[video.id] = .downloading(fraction)
                    }
                }
                try Task.checkCancellation()
                guard inspectionIDs[video.id] == token, let index = videos.firstIndex(where: { $0.id == video.id }) else { return }
                guard let current = PhotosService.fetch(video.id), current.modificationDate == modifiedAt else {
                    throw MediaError.invalid("This video changed during inspection. Refresh the library before trying again.")
                }
                if var facts {
                    facts.bytes = facts.bytes ?? videos[index].facts.bytes
                    videos[index].facts = facts; videos[index].factsAreMeasured = true
                    inspections[video.id] = .ready
                } else {
                    inspections[video.id] = .needsDownload
                    if promptIfUnavailable { inspectionPrompt = InspectionPrompt(id: video.id, name: video.name, bytes: video.facts.bytes) }
                }
            } catch {
                guard inspectionIDs[video.id] == token else { return }
                inspections[video.id] = error is CancellationError ? nil : .failed(error.localizedDescription)
            }
        }
    }

    func connect() {
        guard !isBusy, !isLoading, !indexingSizes else { return }
        let refreshing = connected && !demo
        let previous = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
        let previousSelection = selected, previousFocus = focusedID
        isLoading = true; activity = "Opening your Photos library…"
        Task {
            do {
                try await PhotosService.authorize()
                await reloadHistory()
                var loaded = await PhotosService.videos(photos: mediaMode == .photos)
                for index in loaded.indices {
                    if let old = previous[loaded[index].id], old.asset?.modificationDate == loaded[index].asset?.modificationDate, old.hasInspectedFacts {
                        loaded[index].facts = old.facts; loaded[index].factsAreMeasured = true
                    } else if let record = history.first(where: { $0.sourceID == loaded[index].id && $0.sourceModifiedAt == loaded[index].asset?.modificationDate }), let facts = record.sourceFacts {
                        loaded[index].facts = facts; loaded[index].factsAreMeasured = true
                    }
                }
                let valid = Set(loaded.map(\.id))
                let loadedByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
                for id in Array(inspectionTasks.keys) where !valid.contains(id) || previous[id]?.asset?.modificationDate != loadedByID[id]?.asset?.modificationDate {
                    cancelInspection(id: id)
                }
                inspections = inspections.filter { valid.contains($0.key) && previous[$0.key]?.asset?.modificationDate == loadedByID[$0.key]?.asset?.modificationDate }
                videos = loaded
                connected = true; demo = false
                selected = refreshing ? previousSelection.intersection(Set(loaded.filter { $0.unsupportedReason == nil }.map(\.id))) : []
                let canKeepFocus = refreshing && previousFocus.map(valid.contains) == true
                if canKeepFocus {
                    focusedID = previousFocus
                    if let id = previousFocus, previous[id]?.asset?.modificationDate != loadedByID[id]?.asset?.modificationDate {
                        loadPreview(preservingPosition: false)
                    }
                } else {
                    focusedID = nil; player?.pause(); player = nil
                }
                await reconcileImportedCopies()
                refreshSharing(force: true)
                isLoading = false; activity = "\(videos.count) \(mediaMode.rawValue.lowercased()) in your library"
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
                if let video = focused { inspect(video, allowNetwork: false) }
            } catch { isLoading = false; activity = ""; notice = AppNotice(text: error.localizedDescription) }
        }
    }

    func openFiles() {
        guard !isBusy, !isLoading, !indexingSizes else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = mediaMode == .photos ? [.jpeg, .heic] : [.movie]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        clearInspections()
        let urls = panel.urls
        isLoading = true; activity = "Inspecting video files…"
        Task {
            var loaded: [LibraryVideo] = []
            for url in urls {
                do {
                    let info: VideoFacts
                    if mediaMode == .photos {
                        let photo = try await Task.detached { try PhotoEncoder.inspect(url) }.value
                        info = VideoFacts(width: photo.width, height: photo.height, duration: 0, frameRate: 0, bytes: photo.bytes)
                    } else { info = try await VideoEncoder.inspect(url).facts }
                    loaded.append(LibraryVideo(id: url.path, name: url.lastPathComponent, asset: nil, fileURL: url, facts: info,
                        date: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(), unsupportedReason: nil, kind: mediaMode == .photos ? .photo : .video))
                } catch { notice = AppNotice(text: "\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            videos = loaded; connected = false; demo = false; replaceOriginals = false
            selected.removeAll(); focusedID = nil; player = nil
            isLoading = false; activity = "\(loaded.count) local \(mediaMode.rawValue.lowercased()) · originals remain in place"
        }
    }

    func focus(_ video: LibraryVideo, inspectLocally: Bool = true) {
        scheduleListReordering()
        guard focusedID != video.id else { return }
        if let id = focusedID, inspections[id]?.isWorking == true { cancelInspection(id: id) }
        focusedID = video.id; previewCompressed = false; loadPreview(preservingPosition: false)
        if inspectLocally { inspect(video, allowNetwork: false) }
    }

    func switchPreview(compressed: Bool) {
        guard previewCompressed != compressed else { return }
        previewCompressed = compressed
        loadPreview()
    }

    func loadPreview(preservingPosition: Bool = true) {
        if preservingPosition {
            if let player {
                let time = player.currentTime()
                previewPosition = time.seconds.isFinite && time.seconds >= 0 ? time : .zero
                previewShouldResume = player.rate > 0
                previewMuted = player.isMuted
            }
        } else {
            previewPosition = .zero; previewShouldResume = false; previewMuted = false
        }
        previewTask?.cancel(); player?.pause(); player = nil; previewError = nil
        guard let video = focused else { return }
        guard !video.kind.isPhoto else { previewLoading = false; return }
        previewLoading = true
        let useCompressed = previewCompressed
        let position = previewPosition, shouldResume = previewShouldResume, muted = previewMuted
        previewTask = Task {
            do {
                let item: AVPlayerItem
                if useCompressed, let url = output(for: video.id) { item = AVPlayerItem(url: url) }
                else if let url = video.fileURL { item = AVPlayerItem(url: url) }
                else if let asset = video.asset { item = try await PhotosService.preview(asset) }
                else { throw MediaError.invalid("Sample data. Open video files or connect Photos for playback.") }
                guard !Task.isCancelled else { return }
                let next = AVPlayer(playerItem: item)
                next.isMuted = muted
                if position.seconds.isFinite, position.seconds > 0 {
                    let seconds = min(position.seconds, max(0, video.facts.duration - 0.001))
                    _ = await next.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                guard !Task.isCancelled, focusedID == video.id, previewCompressed == useCompressed else { next.pause(); return }
                player = next; previewLoading = false
                if shouldResume { next.play() }
            } catch {
                guard !Task.isCancelled else { return }
                previewLoading = false; previewError = error.localizedDescription
            }
        }
    }

    private func clearInspections() {
        for id in Array(inspectionTasks.keys) { cancelInspection(id: id) }
        inspections.removeAll(); inspectionPrompt = nil
    }

    func toggle(_ video: LibraryVideo) {
        guard !isBusy, video.unsupportedReason == nil else { return }
        if selected.contains(video.id) { selected.remove(video.id) } else { selected.insert(video.id) }
    }

    func selectRecommended() {
        selected = Set(visible.filter {
            guard $0.unsupportedReason == nil, let bytes = $0.facts.bytes, bytes > ($0.kind.isPhoto ? 2_000_000 : 100_000_000),
                  let saving = estimatedSavings($0) else { return false }
            return Double(saving) / Double(bytes) >= ($0.kind.isPhoto ? photoSettings.minimumSavings : settings.minimumSavings)
        }.map(\.id))
    }

    func chooseArchive() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Use for backups"
        if panel.runModal() == .OK, let url = panel.url { backupDirectory = url }
    }

    func startBatch(keepOriginals: Bool = false) {
        guard !isBusy, !isInspecting, !demo, let journal else { return }
        let batch = selectedVideos.filter { $0.unsupportedReason == nil }
        guard !batch.isEmpty else { return }
        if replaceOriginals && connected && !keepOriginals && !sharedLibraryReplacementAcknowledged {
            sharedLibraryReplacementPrompt = true; return
        }
        let settings = self.settings, photoSettings = self.photoSettings
        let replace = replaceOriginals && connected && !keepOriginals, archive = backupDirectory
        isBusy = true; overallProgress = 0; cancellation = CancellationFlag(); batchSummary = nil
        let flag = cancellation
        batchTask = Task {
            let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Compressing videos and preserving original archives")
            defer {
                ProcessInfo.processInfo.endActivity(awake)
                isBusy = false; refreshArchiveSpace()
            }
            var summary = BatchSummary(total: batch.count)
            var operationIDs = Set<UUID>()
            var ready: [OperationRecord] = []
            for (index, video) in batch.enumerated() {
                if flag.isCancelled { break }
                activity = "\(index + 1) of \(batch.count) · \(video.name)"
                overallProgress = Double(index) / Double(batch.count)
                if history.contains(where: { $0.sourceID == video.id && $0.replacementID != nil && $0.stage != .reverted }) {
                    statuses[video.id] = RowStatus(text: "Existing copy · check Review")
                    summary.skipped += 1; selected.remove(video.id); continue
                }
                var record = OperationRecord(sourceID: video.id, sourceName: video.name, backupPath: "", outputPath: "", settings: settings)
                record.mediaKind = video.kind
                if video.kind.isPhoto { record.photoSettings = photoSettings }
                operationIDs.insert(record.id)
                let directory = archive.appendingPathComponent(record.id.uuidString)
                let safeName = URL(fileURLWithPath: video.name).lastPathComponent
                let originalURL = directory.appendingPathComponent(safeName)
                let stem = String(URL(fileURLWithPath: safeName).deletingPathExtension().lastPathComponent.prefix(40))
                let outputURL = directory.appendingPathComponent("\(stem) [\(record.id.uuidString)] compressed.\(video.kind.isPhoto ? "heic" : "mov")")
                record.backupPath = originalURL.path; record.outputPath = outputURL.path
                do {
                    try flag.check()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                    let required = (video.facts.bytes ?? 0) * 2 + estimatedBytes(video) + 512_000_000
                    if let capacity, capacity < required { throw MediaError.invalid("The backup disk needs approximately \(DisplayFormat.bytes(required)) free for this video and its smaller copy.") }
                    let original = video.asset.flatMap { PhotosService.fetch($0.localIdentifier) }
                    record.sourceModifiedAt = original?.modificationDate
                    if let original, let identity = SharedLibraryController.identity(original) {
                        let observation = await sharing.inspect([identity])[original.localIdentifier]
                        record.sourceSharedLibrary = observation?.state == .unknown ? (sharing.knownSharedOriginal(original.localIdentifier) ?? observation) : observation
                    }
                    try await journal.save(record)
                    let metadata: ScriptMetadata?
                    if let original {
                        statuses[video.id] = RowStatus(text: "Reading library metadata…")
                        metadata = try await PhotosScript.readMetadata(id: original.localIdentifier)
                        record.sourceTextMetadata = metadata
                        try await journal.save(record)
                        statuses[video.id] = RowStatus(text: "Downloading and archiving…", fraction: 0)
                        try await PhotosService.archive(original, to: originalURL) { progress in
                            Task { @MainActor in self.statuses[video.id] = RowStatus(text: "Downloading and archiving…", fraction: progress) }
                        }
                    } else if let file = video.fileURL {
                        metadata = nil; statuses[video.id] = RowStatus(text: "Archiving original…")
                        try await Task.detached { try FileManager.default.copyItem(at: file, to: originalURL) }.value
                    } else { throw MediaError.invalid("The original is no longer in the library. Refresh and try again.") }
                    try flag.check()
                    if video.kind.isPhoto {
                        try await encodePhoto(video: video, original: original, source: originalURL, output: outputURL,
                                              record: &record, settings: photoSettings, cancellation: flag)
                    } else {
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
                        record.outputBytes = outputInfo.facts.bytes
                    }
                    record.stage = .encoded
                    try await journal.save(record)
                    let before = record.originalBytes ?? 0, after = record.outputBytes ?? .max
                    guard before > 0, after > 0, Double(before - after) / Double(before) >= (video.kind.isPhoto ? photoSettings.minimumSavings : settings.minimumSavings) else {
                        record.stage = .keptOriginal; try await journal.save(record)
                        statuses[video.id] = RowStatus(text: "Skipped · below minimum savings")
                        summary.skipped += 1
                        await reloadHistory(); continue
                    }
                    try flag.check()
                    if let original, let metadata {
                        statuses[video.id] = RowStatus(text: "Importing and restoring metadata…")
                        let albums = PhotosService.regularAlbums(containing: original)
                        record.replacementID = try await PhotosService.importVideo(outputURL, original: original, albums: albums,
                            pairedVideo: record.outputIsLivePhoto ? record.pairedVideoPath.map { URL(fileURLWithPath: $0) } : nil)
                        record.stage = .imported; try await journal.save(record)
                        try PhotosService.verifyImport(record.replacementID!, original: original, albums: albums,
                                                       expectedLive: video.kind.isPhoto ? record.outputIsLivePhoto : nil)
                        if let photo = record.outputPhotoFacts, let imported = PhotosService.fetch(record.replacementID!),
                           (imported.pixelWidth != photo.width || imported.pixelHeight != photo.height) {
                            throw MediaError.invalid("The imported photo's dimensions were not verified. Original retained.")
                        }
                        try await PhotosScript.restoreMetadata(metadata, id: record.replacementID!)
                        record.metadataVerified = true
                        record.replacementModifiedAt = PhotosService.fetch(record.replacementID!)?.modificationDate
                        record.stage = .readyToDelete
                        try await journal.save(record)
                        if replace && !record.requiresSharedLibraryReview { ready.append(record) }
                    } else {
                        record.stage = .keptOriginal; try await journal.save(record)
                    }
                    let saved = (record.originalBytes ?? 0) - (record.outputBytes ?? 0)
                    summary.completed += 1; summary.savedBytes += max(0, saved)
                    statuses[video.id] = RowStatus(text: record.requiresSharedLibraryReview ? "Shared original kept · check Review" : "Copy ready · \(DisplayFormat.bytes(saved)) smaller")
                    selected.remove(video.id)
                } catch {
                    if error is CancellationError { summary.interrupted += 1 } else { summary.failed += 1 }
                    record.stage = .failed; record.error = error is CancellationError ? "Stopped; original retained." : error.localizedDescription
                    try? await journal.save(record)
                    statuses[video.id] = RowStatus(text: record.error ?? "Failed", failed: true)
                }
                await reloadHistory()
            }
            if !flag.isCancelled, !ready.isEmpty { await deleteReady(ready) }
            overallProgress = 1
            activity = flag.isCancelled ? "Stopped safely. Ready copies and originals are retained." : "Batch finished. Open Review to compare your copies."
            await reloadHistory()
            refreshSharing(force: true)
            summary.originalsDeleted = history.filter { operationIDs.contains($0.id) && $0.stage == .originalDeleted }.count
            summary.stopped = flag.isCancelled
            batchSummary = summary
        }
    }

    func stop() { cancellation.cancel(); activity = "Stopping safely · the current iCloud download may finish first…" }

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

    func deleteReady(_ records: [OperationRecord], markReviewed: Bool = false) async {
        guard let journal else { return }
        var candidates: [(OperationRecord, PHAsset)] = []
        for record in records {
            if !markReviewed && cancellation.isCancelled { return }
            do {
                var verified = record
                if !markReviewed {
                    if let original = PhotosService.fetch(record.sourceID), let identity = SharedLibraryController.identity(original),
                       let observation = await sharing.inspect([identity])[record.sourceID] {
                        if observation.state == .shared || record.sourceSharedLibrary?.state != .shared {
                            verified.sourceSharedLibrary = observation
                            try await journal.save(verified)
                        }
                    }
                    if verified.requiresSharedLibraryReview {
                        statuses[record.sourceID] = RowStatus(text: "Shared original kept · check Review")
                        continue
                    }
                }
                if let id = record.replacementID, let replacement = PhotosService.fetch(id),
                   let expected = record.replacementModifiedAt, replacement.modificationDate != expected {
                    activity = "Rechecking replacement resources and metadata…"
                    verified.replacementModifiedAt = try await PhotosService.revalidateChangedReplacement(record, original: PhotosService.fetch(record.sourceID))
                    try await journal.save(verified)
                }
                guard record.isDeletionCandidate,
                      let original = PhotosService.fetch(record.sourceID),
                      let replacementID = record.replacementID, let replacement = PhotosService.fetch(replacementID),
                      original.modificationDate == record.sourceModifiedAt,
                      verified.replacementModifiedAt == nil || replacement.modificationDate == verified.replacementModifiedAt,
                      record.kind.isPhoto || abs(original.duration - replacement.duration) < 0.25 else {
                    throw MediaError.invalid("An original or replacement changed or disappeared. Original retained.")
                }
                for (path, bytes) in record.archiveFiles {
                    let size = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize
                    guard bytes != nil, size.map(Int64.init) == bytes else { throw MediaError.invalid("An archived resource is missing or changed. Original retained.") }
                }
                candidates.append((verified, original))
            } catch {
                statuses[record.sourceID] = RowStatus(text: error.localizedDescription, failed: true)
                var failed = record; failed.error = error.localizedDescription
                try? await journal.save(failed)
                notice = AppNotice(text: error.localizedDescription)
            }
        }
        guard !candidates.isEmpty else { return }
        // Revalidation may await a resource download. A stop requested during
        // that await must still prevent automatic deletion of prepared originals.
        guard markReviewed || !cancellation.isCancelled else { return }
        activity = "Confirm original deletion in the macOS Photos dialog…"
        do {
            try await PhotosService.delete(candidates.map(\.1))
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
            statuses[record.sourceID] = RowStatus(text: "Replaced · original archived locally")
            videos.removeAll { $0.id == record.sourceID }; selected.remove(record.sourceID)
            if focusedID == record.sourceID { player?.pause(); player = nil; focusedID = nil }
        }
    }

    func reloadHistory() async { if let journal { history = await journal.all() } }

    func confirmAutomaticReplacement() {
        sharedLibraryReplacementPrompt = false; sharedLibraryReplacementAcknowledged = true; startBatch()
    }

    private func reconcileImportedCopies() async {
        guard let journal else { return }
        await reloadHistory()
        for var record in history where record.replacementID == nil && record.outputBytes != nil && [.encoded, .imported, .failed].contains(record.stage) {
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
        mediaMode = .videos
        clearInspections()
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
