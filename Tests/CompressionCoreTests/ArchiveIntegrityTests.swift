import XCTest
@testable import CompressionCore

final class ArchiveIntegrityTests: XCTestCase {
    func testSameSizeCorruptionIsRejectedAndChecksumsSurviveRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.mov"), output = directory.appendingPathComponent("output.mov")
        try Data("original bytes".utf8).write(to: original)
        try Data("small".utf8).write(to: output)
        var record = OperationRecord(sourceID: "asset", sourceName: "original.mov", backupPath: original.path, outputPath: output.path, settings: .init())
        record.originalFingerprint = try ArchiveIntegrity.fingerprint(original)
        record.outputFingerprint = try ArchiveIntegrity.fingerprint(output)
        record.originalBytes = record.originalFingerprint?.bytes; record.outputBytes = record.outputFingerprint?.bytes
        record.stage = .encoded
        let journalURL = directory.appendingPathComponent("operations.json")
        try await OperationJournal(url: journalURL).save(record)
        let records = await (try OperationJournal(url: journalURL)).all()
        let saved = try XCTUnwrap(records.first)
        XCTAssertEqual(saved.originalFingerprint, record.originalFingerprint)
        try ArchiveIntegrity.verify(saved)
        try Data("ORIGINAL BYTES".utf8).write(to: original)
        XCTAssertEqual(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(saved.originalBytes!))
        XCTAssertThrowsError(try ArchiveIntegrity.verify(saved))
        XCTAssertThrowsError(try BatchRecovery.verifyReusableOriginal(saved, cancellation: .init()))
        try Data("original bytes".utf8).write(to: original)
        try Data("SMALL".utf8).write(to: output)
        XCTAssertThrowsError(try ArchiveIntegrity.verify(saved))
    }

    func testMotionIsVerifiedEvenWhenCopyIsAStill() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.jpg"), output = directory.appendingPathComponent("output.heic"), motion = directory.appendingPathComponent("motion.mov")
        try Data(repeating: 1, count: 100).write(to: original)
        try Data(repeating: 2, count: 50).write(to: output)
        try Data(repeating: 3, count: 200).write(to: motion)
        var record = OperationRecord(sourceID: "asset", sourceName: "original.jpg", backupPath: original.path, outputPath: output.path, settings: .init())
        record.mediaKind = .livePhoto; record.photoSettings = .init(); record.photoSettings?.convertLiveToStill = true
        record.photoFacts = PhotoFacts(width: 10, height: 10, bytes: 100, format: "public.jpeg")
        record.outputPhotoFacts = PhotoFacts(width: 10, height: 10, bytes: 50, format: "public.heic")
        record.pairedVideoPath = motion.path; record.pairedVideoBytes = 200
        record.originalBytes = 300; record.outputBytes = 50
        record.originalFingerprint = try ArchiveIntegrity.fingerprint(original)
        record.outputFingerprint = try ArchiveIntegrity.fingerprint(output)
        record.pairedVideoFingerprint = try ArchiveIntegrity.fingerprint(motion)
        try ArchiveIntegrity.verify(record)
        try Data(repeating: 4, count: 200).write(to: motion)
        XCTAssertThrowsError(try ArchiveIntegrity.verify(record))
    }

    func testLegacyAndMissingArchivesFailClosedWithoutCreatingChecksums() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original")
        try Data([1, 2, 3]).write(to: url)
        XCTAssertThrowsError(try ArchiveIntegrity.verify(url, bytes: 3, fingerprint: nil))
        let fingerprint = try ArchiveIntegrity.fingerprint(url)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try ArchiveIntegrity.verify(url, bytes: 3, fingerprint: fingerprint))
        try Data().write(to: url)
        XCTAssertThrowsError(try ArchiveIntegrity.fingerprint(url))
    }

    func testFingerprintCancellationAndKnownSHA256() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try ArchiveIntegrity.fingerprint(url).sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let cancellation = CancellationFlag(); cancellation.cancel()
        XCTAssertThrowsError(try ArchiveIntegrity.fingerprint(url, cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
    }

    func testPartialFilesArePreservedWithoutOverwritingAndQueueIsAtomic() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("partial.mov")
        try Data("unfinished".utf8).write(to: output)
        try BatchRecovery.preserveUnverifiedFile(at: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Interrupted files"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: files[0]), Data("unfinished".utf8))
        let records = (0..<3).map { OperationRecord(sourceID: "asset-\($0)", sourceName: "source", backupPath: "original", outputPath: "output", settings: .init()) }
        let journalURL = directory.appendingPathComponent("operations.json")
        try await OperationJournal(url: journalURL).save(records)
        let reopened = await (try OperationJournal(url: journalURL)).all()
        XCTAssertEqual(Set(reopened.map(\.id)), Set(records.map(\.id)))
        XCTAssertTrue(reopened.allSatisfy(\.canResume))
        var completed = records[0]
        for stage in [OperationStage.readyToDelete, .originalDeleted, .keptOriginal, .reverting, .reverted] {
            completed.stage = stage; XCTAssertFalse(completed.canResume)
        }
    }

    func testImportedAndAmbiguousLegacyWorkCannotBeDismissedToBypassRecovery() {
        var record = OperationRecord(sourceID: "original", sourceName: "source", backupPath: "archive", outputPath: "output", settings: .init())
        XCTAssertTrue(record.canDismissResume)
        record.importAttempted = true
        XCTAssertFalse(record.canDismissResume)
        record.importAttempted = nil; record.outputBytes = 500
        XCTAssertFalse(record.canDismissResume) // Legacy output may already be imported.
        record.originalFingerprint = FileFingerprint(bytes: 1000, sha256: "checksum")
        XCTAssertTrue(record.canDismissResume)
        record.replacementID = "copy"
        XCTAssertFalse(record.canDismissResume)
        record.resumeDismissed = true
        XCTAssertFalse(record.canResume)
    }

    func testMissingMalformedAndInconsistentChecksumManifestsNeverGrantDeletion() {
        var record = OperationRecord(sourceID: "original", sourceName: "source", backupPath: "archive", outputPath: "output", settings: .init())
        record.originalBytes = 1000; record.outputBytes = 500
        record.stage = .readyToDelete; record.metadataVerified = true; record.replacementID = "copy"
        XCTAssertFalse(record.isDeletionCandidate)
        record.originalFingerprint = FileFingerprint(bytes: 1000, sha256: String(repeating: "a", count: 64))
        record.outputFingerprint = FileFingerprint(bytes: 500, sha256: "invalid")
        XCTAssertFalse(record.isDeletionCandidate)
        record.outputFingerprint = FileFingerprint(bytes: 501, sha256: String(repeating: "b", count: 64))
        XCTAssertFalse(record.isDeletionCandidate)
        record.outputFingerprint = FileFingerprint(bytes: 500, sha256: String(repeating: "b", count: 64))
        XCTAssertTrue(record.isDeletionCandidate)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
