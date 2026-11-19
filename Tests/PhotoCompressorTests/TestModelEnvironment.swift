import Foundation
@testable import PhotoCompressor

// An isolated temporary folder, preferences suite, and journal for AppModel tests.
struct TestModelEnvironment {
    let directory: URL
    let preferences: UserDefaults
    private let suite = "PhotoCompressorTests." + UUID().uuidString

    init(_ name: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoCompressor-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        preferences = UserDefaults(suiteName: suite)!
    }

    var journalURL: URL { directory.appendingPathComponent("operations.json") }

    @MainActor func model() -> AppModel { AppModel(preferences: preferences, journalURL: journalURL) }

    func remove() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
