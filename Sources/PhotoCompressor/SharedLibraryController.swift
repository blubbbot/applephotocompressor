import AppKit
import Photos
import CompressionCore

/// Opt-in metadata inspection. The user chooses the same System Photo Library
/// connected through PhotoKit; public resource identities are matched before a
/// database observation is shown. No private PhotoKit selectors are used.
@MainActor
final class SharedLibraryController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var library: URL?
    @Published private(set) var observations: [String: SharedLibraryObservation] = [:]
    @Published private(set) var status = "Choose your connected System Photo Library to enable read-only detection."
    @Published private(set) var checking = false
    private var configuration = UUID()
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    // Preserve shared evidence for the post-replacement Review hint if a later
    // metadata read is temporarily unavailable.
    private var lastKnownShared: [String: SharedLibraryObservation] = [:]
    private var refreshRevision = UUID()

    init() {
        enabled = UserDefaults.standard.bool(forKey: "sharedLibraryDetectionEnabled")
        if let bookmark = UserDefaults.standard.data(forKey: "sharedLibraryDetectionBookmark") {
            var stale = false
            do {
                library = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                status = stale ? "Library access needs renewal. Choose the library again." : "Connect Photos to check the selected library."
                if stale { library = nil }
            } catch { status = "Library access is unavailable. Choose the library again." }
        }
    }

    func chooseLibrary() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose the connected System Photo Library"
        panel.message = "Select the .photoslibrary package used by Connect Photos Library. A backup or another library can contain stale matching IDs. Metadata is read only; photo and video files are not downloaded."
        panel.prompt = "Use for detection"
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = library?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard url.pathExtension.lowercased() == "photoslibrary" else {
            status = "Choose a .photoslibrary package, rather than a folder inside it."; return false
        }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            configuration = UUID(); refreshTask?.cancel(); checking = false; observations = [:]; lastKnownShared = [:]
            library = url; enabled = true; lastRefresh = .distantPast
            UserDefaults.standard.set(bookmark, forKey: "sharedLibraryDetectionBookmark")
            UserDefaults.standard.set(true, forKey: "sharedLibraryDetectionEnabled")
            status = "Library selected. Connect Photos to match assets."
            return true
        } catch { status = "Could not retain read-only library access: \(error.localizedDescription)"; return false }
    }

    func setEnabled(_ value: Bool) {
        configuration = UUID(); refreshTask?.cancel(); checking = false
        enabled = value; observations = [:]; lastKnownShared = [:]; lastRefresh = .distantPast
        UserDefaults.standard.set(value, forKey: "sharedLibraryDetectionEnabled")
        status = value ? "Refresh to check the selected library." : "Detection is off. Sharing stays Unknown."
    }

    func observation(for id: String) -> SharedLibraryObservation {
        guard enabled else { return unknown("Optional database detection is off.") }
        if let result = observations[id], Date().timeIntervalSince(result.checkedAt) < 120 { return result }
        return unknown("No recent matching observation. Refresh sharing metadata. \(status)")
    }

    func knownSharedOriginal(_ id: String) -> SharedLibraryObservation? { enabled ? lastKnownShared[id] : nil }

    func refresh(_ assets: [SharedLibraryAssetIdentity], force: Bool = false) {
        guard enabled, library != nil, !checking, force || Date().timeIntervalSince(lastRefresh) > 30 else { return }
        refreshTask = Task { _ = await inspect(assets) }
    }

    func refresh(identities: [SharedLibraryAssetIdentity], extraIDs: [String], force: Bool = false) {
        guard enabled, library != nil, force || Date().timeIntervalSince(lastRefresh) > 30 else { return }
        refreshTask?.cancel()
        let token = UUID(); refreshRevision = token
        refreshTask = Task {
            // Fetch only history assets missing from the already-indexed list.
            // Resource enumeration and PhotoKit fetching never run on the UI actor.
            let worker = Task.detached(priority: .utility) {
                var result = Dictionary(identities.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
                let missing = Set(extraIDs).subtracting(result.keys)
                PHAsset.fetchAssets(withLocalIdentifiers: Array(missing), options: nil).enumerateObjects { asset, _, stop in
                    if Task.isCancelled { stop.pointee = true; return }
                    if let identity = Self.identity(asset) { result[identity.localIdentifier] = identity }
                }
                return Array(result.values)
            }
            let assets = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, refreshRevision == token else { return }
            _ = await inspect(assets)
        }
    }

    /// A fresh read before compression/deletion does not rely on cached badges.
    @discardableResult
    func inspect(_ assets: [SharedLibraryAssetIdentity]) async -> [String: SharedLibraryObservation] {
        guard enabled, let library, !assets.isEmpty else { return [:] }
        let token = configuration
        checking = true
        defer { if token == configuration { checking = false } }
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                let scoped = library.startAccessingSecurityScopedResource()
                defer { if scoped { library.stopAccessingSecurityScopedResource() } }
                return try SharedLibraryReader.read(library: library, assets: assets)
            }.value
            guard token == configuration else { return [:] }
            observations.merge(snapshot.observations) { old, new in old.checkedAt > new.checkedAt ? old : new }
            for (id, observation) in snapshot.observations {
                if observation.state == .shared, (lastKnownShared[id]?.checkedAt ?? .distantPast) <= observation.checkedAt { lastKnownShared[id] = observation }
                else if observation.state == .personal, (lastKnownShared[id]?.checkedAt ?? .distantPast) <= observation.checkedAt { lastKnownShared[id] = nil }
            }
            lastRefresh = snapshot.checkedAt
            status = "Checked \(snapshot.observations.count) items · \(library.lastPathComponent). Results are advisory."
            return snapshot.observations
        } catch {
            guard token == configuration else { return [:] }
            let results = Dictionary(assets.map { ($0.localIdentifier, unknown(error.localizedDescription)) }, uniquingKeysWith: { _, new in new })
            observations.merge(results) { _, new in new }
            lastRefresh = Date(); status = error.localizedDescription
            return results
        }
    }

    nonisolated static func identity(_ asset: PHAsset) -> SharedLibraryAssetIdentity? {
        let video = asset.mediaType == .video
        guard video || asset.mediaType == .image,
              let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == (video ? .video : .photo) }) else { return nil }
        return SharedLibraryAssetIdentity(localIdentifier: asset.localIdentifier, filename: resource.originalFilename,
                                          isVideo: video, creationDate: asset.creationDate)
    }

    private func unknown(_ detail: String) -> SharedLibraryObservation { SharedLibraryObservation(state: .unknown, detail: detail) }
}

extension AppModel {
    func chooseSharingLibrary() {
        guard !isBusy else { return }
        if sharing.chooseLibrary() { refreshSharing(force: true) }
    }

    func refreshSharing(force: Bool = false) {
        guard connected, !demo, sharing.enabled else { return }
        let identities = videos.compactMap(\.sharingIdentity)
        let ids = history.flatMap { [$0.sourceID, $0.replacementID, $0.restoredOriginalID].compactMap { $0 } }
        sharing.refresh(identities: identities, extraIDs: ids, force: force)
    }

    func sourceSharing(_ record: OperationRecord) -> SharedLibraryObservation? {
        // Review filters describe the original at compression, even when it has
        // already been deleted or the replacement is now in Personal Library.
        if let saved = record.sourceSharedLibrary, saved.state != .unknown { return saved }
        let current = sharing.observation(for: record.sourceID)
        return current.state == .unknown ? (record.sourceSharedLibrary ?? current) : current
    }

    func reviewSharingMatches(_ record: OperationRecord, filter: ReviewSharingFilter) -> Bool {
        guard filter != .all else { return true }
        guard record.isPhotosOperation else { return false }
        return filter.includes(original: sourceSharing(record)?.state ?? .unknown,
                               replacement: record.reviewPhotosID.map { sharing.observation(for: $0).state } ?? .unknown,
                               hasPhotosTarget: record.reviewPhotosID != nil)
    }

    var filteredReviewRecords: [OperationRecord] {
        reviewRecords.filter {
            reviewSharingMatches($0, filter: reviewSharingFilter) &&
            (mediaMode != .photos || reviewPhotoTypeFilter.includes(isLivePhoto: $0.kind == .livePhoto, isPanorama: $0.sourceIsPanorama == true))
        }
    }
    func needsSharing(_ record: OperationRecord) -> Bool { reviewSharingMatches(record, filter: .needsSharing) }
}
