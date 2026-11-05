import Foundation
import CompressionCore

enum InspectionStatus {
    case checking
    case needsDownload
    case downloading(Double)
    case ready
    case failed(String)

    var isWorking: Bool {
        switch self { case .checking, .downloading: return true; default: return false }
    }
}

struct InspectionPrompt: Identifiable {
    let id: String
    let name: String
    let bytes: Int64?

    var message: String {
        let size = bytes.map { " (approximately \(DisplayFormat.bytes($0)))" } ?? ""
        return "Photos needs the original of \(name) to inspect its frame rate and HDR. This may download the video\(size) from iCloud and use local disk space. Inspection only reads metadata."
    }
}

struct BatchSummary {
    let total: Int
    var completed = 0
    var skipped = 0
    var failed = 0
    var interrupted = 0
    var savedBytes: Int64 = 0
    var originalsDeleted = 0
    var stopped = false

    var title: String { stopped ? "Batch stopped safely" : "Batch finished" }
    var details: String {
        var parts = ["\(completed) copies ready", "\(skipped) skipped", "\(failed) failed"]
        if interrupted > 0 { parts.append("\(interrupted) interrupted") }
        let notStarted = total - completed - skipped - failed - interrupted
        if notStarted > 0 { parts.append("\(notStarted) not started") }
        if originalsDeleted > 0 { parts.append("\(originalsDeleted) originals replaced") }
        return parts.joined(separator: " · ")
    }
}

struct ArchiveSpaceSnapshot: Sendable {
    let availableBytes: Int64?
    let volumeName: String?
    let error: String?
    var volumePath: String? = nil

    static func read(at directory: URL) -> ArchiveSpaceSnapshot {
        do {
            let components = directory.standardizedFileURL.pathComponents
            if components.count > 2, components[1] == "Volumes" {
                let mount = URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2])
                guard FileManager.default.fileExists(atPath: mount.path) else {
                    return ArchiveSpaceSnapshot(availableBytes: nil, volumeName: components[2], error: "The archive disk is not connected.")
                }
            }
            var existing = directory
            while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
                existing.deleteLastPathComponent()
            }
            let values = try existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeLocalizedNameKey, .volumeURLKey])
            let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
            return ArchiveSpaceSnapshot(availableBytes: available, volumeName: values.volumeLocalizedName, error: nil, volumePath: values.volume?.path)
        } catch {
            return ArchiveSpaceSnapshot(availableBytes: nil, volumeName: nil, error: "Disk space unavailable: \(error.localizedDescription)")
        }
    }
}
