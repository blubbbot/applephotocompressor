import Foundation
import CompressionCore

/// Value snapshots only: no PhotoKit, file-system, or view work in this builder.
/// The model runs it off the main actor and publishes one cached list.
enum LibraryListIndex {
    struct Query {
        var search = ""
        var minimumSize: Int64 = 0
        var hideUnsupported = true
        var hideProcessed = true
        var processedIDs = Set<String>()
        var outputIDs = Set<String>()
        var sharingFilter: LibrarySharingFilter = .all
        var sharing: [String: SharedLibraryObservation] = [:]
        var sharingEnabled = false
        var photoFilter: PhotoTypeFilter = .all
        var sort: VideoSort = .largest
        var settings = CompressionSettings()
        var photoSettings = PhotoCompressionSettings()
        var now = Date()
    }

    struct Result {
        let items: [LibraryVideo]
        let order: StableListOrder<String>
    }

    static func build(_ items: [LibraryVideo], query: Query, order previous: StableListOrder<String>, resort: Bool, applyImmediately: Bool) throws -> Result {
        try Task.checkCancellation()
        var order = previous
        if resort {
            var keys: [(id: String, value: Double)] = []
            keys.reserveCapacity(items.count)
            for item in items {
                try Task.checkCancellation()
                let value: Double
                switch query.sort {
                case .largest: value = Double(item.facts.bytes ?? 0)
                case .newest: value = item.date.timeIntervalSinceReferenceDate
                case .longest: value = item.facts.duration
                case .savings: value = Double(max(0, (item.facts.bytes ?? 0) - estimatedBytes(item, settings: query.settings, photoSettings: query.photoSettings)))
                }
                keys.append((item.id, value))
            }
            let proposed = keys.sorted { $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value }.map(\.id)
            if applyImmediately { order.apply(proposed) } else { order.propose(proposed) }
        }
        var matching: [String: LibraryVideo] = [:]
        matching.reserveCapacity(items.count)
        for item in items {
            try Task.checkCancellation()
            guard query.search.isEmpty || item.name.localizedCaseInsensitiveContains(query.search),
                  !query.hideUnsupported || item.unsupportedReason == nil,
                  !query.hideProcessed || (!query.processedIDs.contains(item.id) && !query.outputIDs.contains(item.id)),
                  query.minimumSize == 0 || (item.facts.bytes ?? 0) >= query.minimumSize,
                  query.photoFilter.includes(isLivePhoto: item.kind == .livePhoto, isPanorama: item.isPanorama) else { continue }
            if query.sharingFilter != .all {
                let observed = query.sharing[item.id]
                let state: SharedLibraryState
                if query.sharingEnabled, let observed, query.now.timeIntervalSince(observed.checkedAt) < 120 { state = observed.state }
                else { state = .unknown }
                guard query.sharingFilter.includes(state) else { continue }
            }
            matching[item.id] = item
        }
        try Task.checkCancellation()
        return Result(items: order.ids.compactMap { matching[$0] }, order: order)
    }

    static func estimatedBytes(_ item: LibraryVideo, settings: CompressionSettings, photoSettings: PhotoCompressionSettings) -> Int64 {
        guard item.kind.isPhoto else { return CompressionPlan(facts: item.facts, settings: settings).estimatedBytes }
        let size = item.facts.bytes ?? Int64(item.facts.width * item.facts.height / 3)
        let dimensions = PhotoEncoder.dimensions(width: item.facts.width, height: item.facts.height, resolution: photoSettings.resolution)
        let ratio = Double(dimensions.0 * dimensions.1) / Double(max(1, item.facts.width * item.facts.height))
        let baseFraction = item.photoFormat == "public.heic" ? 0.9 : 0.65
        let fraction = item.kind == .livePhoto && !photoSettings.convertLiveToStill ? 0.9 : min(0.98, max(0.1, baseFraction * photoSettings.quality / 0.8 * ratio))
        return Int64(Double(size) * fraction)
    }
}
