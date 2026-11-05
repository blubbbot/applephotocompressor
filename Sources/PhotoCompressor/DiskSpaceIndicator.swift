import SwiftUI
import CompressionCore

/// Fits the existing footer/expanded toolbar row; details live in the tooltip.
struct DiskSpaceIndicator: View {
    @EnvironmentObject private var model: AppModel
    private var archive: ArchiveSpaceSnapshot? { model.archiveSpace }
    private var mac: ArchiveSpaceSnapshot? { model.workingSpace }
    private var level: DiskSpaceLevel {
        max(DiskSpaceLevel.assess(available: archive?.availableBytes, required: model.estimatedArchiveBytes),
            DiskSpaceLevel.assess(available: mac?.availableBytes, required: 0))
    }
    private var label: String {
        if let available = archive?.availableBytes {
            if let working = mac?.availableBytes, working < 10_000_000_000,
               archive?.volumePath != mac?.volumePath, working < available {
                return "Mac low · \(DisplayFormat.bytes(working)) free"
            }
            return "\(level >= .low ? "Low space · " : "")\(DisplayFormat.bytes(available)) free"
        }
        return archive?.error == nil ? "Checking space…" : "Check backup disk"
    }
    private var detail: String {
        var lines = ["Archive: \(archive?.availableBytes.map(DisplayFormat.bytes) ?? "Unavailable") free\(archive?.volumeName.map { " on " + $0 } ?? "")."]
        if let error = archive?.error { lines.append(error) }
        if let mac { lines.append("Mac working space: \(mac.availableBytes.map(DisplayFormat.bytes) ?? "Unavailable") free.") }
        if !model.selected.isEmpty { lines.append("Selection needs \(model.unknownSelectedSizes > 0 ? "at least " : "approximately ")\(DisplayFormat.bytes(model.estimatedArchiveBytes)) for originals, copies, and working space.") }
        lines.append("Orange below 10 GB or when the selection may not fit; red below 2 GB. Unknown original sizes can increase the estimate. Refreshed every 10 seconds, including during conversion.")
        return lines.joined(separator: "\n")
    }
    var body: some View {
        Label(label, systemImage: level >= .low || archive?.error != nil ? "externaldrive.badge.exclamationmark" : "externaldrive")
            .font(.caption.monospacedDigit()).foregroundStyle(level == .critical ? Color.red : level == .low || archive?.error != nil ? Color.orange : Color.secondary)
            .lineLimit(1).help(detail).accessibilityLabel(label).accessibilityHint(detail)
    }
}
