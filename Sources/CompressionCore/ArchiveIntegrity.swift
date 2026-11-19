import Foundation
import CryptoKit

public struct FileFingerprint: Codable, Equatable, Sendable {
    public let bytes: Int64
    public let sha256: String

    public init(bytes: Int64, sha256: String) {
        self.bytes = bytes; self.sha256 = sha256
    }

    func matches(bytes expected: Int64?) -> Bool {
        bytes > 0 && bytes == expected && sha256.count == 64 && sha256.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

public enum ArchiveIntegrity {
    public static func fingerprint(_ url: URL, cancellation: CancellationFlag = CancellationFlag()) throws -> FileFingerprint {
        try cancellation.check()
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), count: Int64 = 0
        while true {
            try cancellation.check()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hash.update(data: data); count += Int64(data.count)
        }
        // Use a fresh URL to avoid Foundation's cached resource values.
        let after = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard count > 0, before.fileSize == after.fileSize, after.fileSize.map(Int64.init) == count,
              before.contentModificationDate == after.contentModificationDate else {
            throw MediaError.invalid("An archive is empty or changed while being checked. No Photos item was removed.")
        }
        return FileFingerprint(bytes: count, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    public static func verify(_ url: URL, bytes: Int64?, fingerprint expected: FileFingerprint?, cancellation: CancellationFlag = CancellationFlag()) throws {
        guard let expected, expected.matches(bytes: bytes) else {
            throw MediaError.invalid("This archive has no recorded SHA-256 checksum. Automatic deletion and restoration are blocked. Keep the original and archives; older operations require manual recovery.")
        }
        guard try fingerprint(url, cancellation: cancellation) == expected else {
            throw MediaError.invalid("An archived file is missing or its SHA-256 checksum changed. No Photos item was removed. Reconnect the correct archive disk or restore a verified backup.")
        }
    }

    public static func verifyOriginal(_ record: OperationRecord, cancellation: CancellationFlag = CancellationFlag()) throws {
        try verify(URL(fileURLWithPath: record.backupPath), bytes: record.originalFileBytes, fingerprint: record.originalFingerprint, cancellation: cancellation)
        if record.kind == .livePhoto {
            guard let path = record.pairedVideoPath else { throw MediaError.invalid("The archived Live Photo motion is missing.") }
            try verify(URL(fileURLWithPath: path), bytes: record.pairedVideoBytes, fingerprint: record.pairedVideoFingerprint, cancellation: cancellation)
        }
    }

    public static func verify(_ record: OperationRecord, cancellation: CancellationFlag = CancellationFlag()) throws {
        guard record.completePhotoResources else { throw MediaError.invalid("The photo archive manifest is incomplete. No Photos item was removed.") }
        try verifyOriginal(record, cancellation: cancellation)
        try verify(URL(fileURLWithPath: record.outputPath), bytes: record.outputFileBytes, fingerprint: record.outputFingerprint, cancellation: cancellation)
    }
}
