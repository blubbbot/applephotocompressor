import Foundation

public enum BatchRecovery {
    // A file without a durable checksum may be a partial download/encode. Keep
    // it for inspection in the same operation folder, without overwriting it.
    public static func preserveUnverifiedFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let directory = url.deletingLastPathComponent().appendingPathComponent("Interrupted files")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
    }

    public static func verifyReusableOriginal(_ record: OperationRecord, cancellation: CancellationFlag) throws {
        try ArchiveIntegrity.verify(URL(fileURLWithPath: record.backupPath), bytes: record.originalFileBytes,
                                    fingerprint: record.originalFingerprint, cancellation: cancellation)
        if record.pairedVideoFingerprint != nil {
            guard let path = record.pairedVideoPath else { throw MediaError.invalid("The archived Live Photo motion is missing.") }
            try ArchiveIntegrity.verify(URL(fileURLWithPath: path), bytes: record.pairedVideoBytes,
                                        fingerprint: record.pairedVideoFingerprint, cancellation: cancellation)
        }
    }
}
