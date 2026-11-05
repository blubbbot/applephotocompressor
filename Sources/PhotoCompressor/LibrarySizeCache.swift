import Foundation

/// One Photos scripting size pass can serve rapid Videos/Photos switches.
/// Callers may stop waiting without launching another whole-library process.
actor LibrarySizeCache {
    static let shared = LibrarySizeCache { try await PhotosScript.sizes() }
    private let load: @Sendable () async throws -> [String: Int64]
    private var cached: [String: Int64]?
    private var checkedAt = Date.distantPast
    private var inFlight: Task<[String: Int64], Error>?

    init(load: @escaping @Sendable () async throws -> [String: Int64]) { self.load = load }

    func sizes(refresh: Bool = false) async throws -> [String: Int64] {
        if !refresh, let cached, Date().timeIntervalSince(checkedAt) < 120 { return cached }
        if let inFlight { return try await inFlight.value }
        let load = load
        let worker = Task { try await load() }
        inFlight = worker
        do {
            let result = try await worker.value
            cached = result; checkedAt = Date(); inFlight = nil
            return result
        } catch { inFlight = nil; throw error }
    }
}
