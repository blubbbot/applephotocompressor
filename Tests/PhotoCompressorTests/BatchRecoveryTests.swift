import XCTest
import ImageIO
import UniformTypeIdentifiers
import CompressionCore
@testable import PhotoCompressor

@MainActor
final class BatchRecoveryTests: XCTestCase {
    func testArchivedOriginalIsReusedAndPartialOutputPreservedWithSameOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var record = try fixture.archivedRecord()
        try Data("partial output".utf8).write(to: URL(fileURLWithPath: record.outputPath))
        try FileManager.default.removeItem(at: fixture.source)
        record.stage = .failed
        try await fixture.journal.save(record)
        let model = fixture.model()
        await model.reloadHistory()
        model.resumeInterrupted(record)
        await model.batchTask?.value
        let result = try XCTUnwrap(model.history.first)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(result.id, record.id); XCTAssertEqual(result.backupPath, record.backupPath)
        XCTAssertEqual(result.originalFingerprint, record.originalFingerprint)
        XCTAssertEqual(result.stage, .keptOriginal, result.error ?? "")
        XCTAssertNotNil(result.outputFingerprint)
        try ArchiveIntegrity.verify(result)
        let partials = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: record.outputPath).deletingLastPathComponent().appendingPathComponent("Interrupted files"), includingPropertiesForKeys: nil)
        XCTAssertEqual(partials.count, 1)
        XCTAssertEqual(try Data(contentsOf: partials[0]), Data("partial output".utf8))
    }

    func testEncodedCheckpointIsReusedWithoutTouchingOutputOrNeedingSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.encodedRecord()
        let output = URL(fileURLWithPath: record.outputPath)
        let modified = try output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try FileManager.default.removeItem(at: fixture.source)
        try await fixture.journal.save(record)
        let model = fixture.model()
        await model.reloadHistory()
        model.photoSettings.quality = 0.4 // Resume must use the saved settings.
        model.resumeInterrupted(record)
        await model.batchTask?.value
        let result = try XCTUnwrap(model.history.first)
        XCTAssertEqual(result.id, record.id); XCTAssertEqual(result.stage, .keptOriginal, result.error ?? "")
        XCTAssertEqual(result.outputFingerprint, record.outputFingerprint)
        XCTAssertEqual(result.photoSettings, record.photoSettings)
        XCTAssertEqual(try output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        XCTAssertEqual(model.batchSummary?.completed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.deletingLastPathComponent().appendingPathComponent("Interrupted files").path))
    }

    func testCorruptVerifiedOutputBlocksRetryWithoutOverwritingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.encodedRecord()
        let output = URL(fileURLWithPath: record.outputPath)
        let corrupt = Data(repeating: 0xff, count: Int(record.outputFingerprint!.bytes))
        try corrupt.write(to: output)
        try await fixture.journal.save(record)
        let model = fixture.model()
        await model.reloadHistory()
        model.resumeInterrupted(record)
        await model.batchTask?.value
        let result = try XCTUnwrap(model.history.first)
        XCTAssertEqual(result.stage, .failed)
        XCTAssertTrue(result.error?.contains("SHA-256") == true)
        XCTAssertEqual(try Data(contentsOf: output), corrupt)
        XCTAssertNil(result.replacementID)
        XCTAssertEqual(model.batchSummary?.failed, 1)
    }

    func testStoppingQueuesUnstartedItemsAndRestartResumesEntireBatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let second = fixture.directory.appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: fixture.source, to: second)
        let model = fixture.model()
        await model.reloadHistory()
        model.videos = try [fixture.source, second].map { url in
            let facts = try PhotoEncoder.inspect(url)
            return LibraryVideo(id: url.path, name: url.lastPathComponent, asset: nil, fileURL: url,
                facts: .init(width: facts.width, height: facts.height, duration: 0, bytes: facts.bytes), date: .distantPast,
                unsupportedReason: nil, kind: .photo)
        }
        model.selected = Set(model.videos.map(\.id))
        model.startBatch()
        model.stop()
        await model.batchTask?.value
        XCTAssertEqual(model.history.count, 2)
        XCTAssertTrue(model.history.allSatisfy { $0.stage == .preparing && $0.originalFingerprint == nil })
        let ids = Set(model.history.map(\.id))
        let restarted = fixture.model()
        await restarted.reloadHistory()
        restarted.photoSettings.quality = 0.4
        restarted.resumeInterrupted()
        await restarted.batchTask?.value
        XCTAssertEqual(Set(restarted.history.map(\.id)), ids)
        XCTAssertTrue(restarted.history.allSatisfy { $0.stage == .keptOriginal }, restarted.history.compactMap(\.error).joined(separator: ", "))
        XCTAssertTrue(restarted.history.allSatisfy { $0.photoSettings?.quality == 0.8 })
        XCTAssertEqual(restarted.batchSummary?.completed, 2)
        XCTAssertTrue(restarted.resumableRecords.isEmpty)
        for record in restarted.history { try ArchiveIntegrity.verify(record) }
    }

    func testLegacyUnimportedArchiveIsPreservedAndRearchivedFromSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var record = try fixture.archivedRecord()
        record.originalFingerprint = nil
        try Data("untrusted legacy archive".utf8).write(to: URL(fileURLWithPath: record.backupPath))
        try await fixture.journal.save(record)
        let model = fixture.model()
        await model.reloadHistory()
        model.resumeInterrupted(record)
        await model.batchTask?.value
        let result = try XCTUnwrap(model.history.first)
        XCTAssertEqual(result.id, record.id); XCTAssertEqual(result.stage, .keptOriginal, result.error ?? "")
        XCTAssertEqual(result.originalFingerprint, try ArchiveIntegrity.fingerprint(fixture.source))
        let preserved = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: record.backupPath).deletingLastPathComponent().appendingPathComponent("Interrupted files"), includingPropertiesForKeys: nil)
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), Data("untrusted legacy archive".utf8))
    }

    func testDifferentSettingsDoNotCreateDuplicateAndUnimportedWorkCanBeDismissed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.archivedRecord()
        try await fixture.journal.save(record)
        let model = fixture.model()
        await model.reloadHistory()
        let facts = try PhotoEncoder.inspect(fixture.source)
        model.videos = [LibraryVideo(id: fixture.source.path, name: "source.jpg", asset: nil, fileURL: fixture.source,
            facts: .init(width: facts.width, height: facts.height, duration: 0, bytes: facts.bytes), date: .distantPast,
            unsupportedReason: nil, kind: .photo)]
        model.selected = [fixture.source.path]
        model.photoSettings.quality = 0.4
        model.startBatch()
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.showHistory)
        XCTAssertEqual(model.history.count, 1)
        model.dismissInterrupted(record)
        // Dismissal has no media effects and commits to the journal actor.
        while model.isBusy { await Task.yield() }
        XCTAssertTrue(model.resumableRecords.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.backupPath))
        model.startBatch()
        await model.batchTask?.value
        XCTAssertEqual(model.history.count, 2)
        let replacement = try XCTUnwrap(model.history.first { $0.id != record.id })
        XCTAssertEqual(replacement.photoSettings?.quality, 0.4)
        XCTAssertEqual(replacement.stage, .keptOriginal, replacement.error ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.backupPath))
    }

    private struct Fixture {
        let environment: TestModelEnvironment
        let directory: URL
        let source: URL
        let journal: OperationJournal

        init() throws {
            environment = try TestModelEnvironment("recovery-test")
            directory = environment.directory
            source = directory.appendingPathComponent("source.jpg")
            environment.preferences.set(directory.appendingPathComponent("archive").path, forKey: "backupDirectory")
            journal = try OperationJournal(url: environment.journalURL)
            let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 320 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            // Valid JPEG trailing padding gives deterministic savings for this
            // recovery test without depending on HEIC encoder size heuristics.
            let handle = try FileHandle(forWritingTo: source)
            try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 0, count: 200_000)); try handle.close()
        }

        @MainActor func model() -> AppModel { environment.model() }

        func archivedRecord() throws -> OperationRecord {
            var record = OperationRecord(sourceID: source.path, sourceName: "source.jpg", backupPath: "", outputPath: "", settings: .init())
            let folder = directory.appendingPathComponent("archive").appendingPathComponent(record.id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let backup = folder.appendingPathComponent("source.jpg")
            try FileManager.default.copyItem(at: source, to: backup)
            record.backupPath = backup.path; record.outputPath = folder.appendingPathComponent("copy.heic").path
            record.mediaKind = .photo; record.photoSettings = .init()
            record.photoFacts = try PhotoEncoder.inspect(backup)
            record.originalFingerprint = try ArchiveIntegrity.fingerprint(backup)
            record.originalBytes = record.photoFacts!.bytes
            record.sourceFacts = .init(width: 320, height: 240, duration: 0, frameRate: 0, bytes: record.originalBytes)
            record.stage = .archived
            return record
        }

        func encodedRecord() throws -> OperationRecord {
            var record = try archivedRecord()
            let output = URL(fileURLWithPath: record.outputPath)
            record.outputPhotoFacts = try PhotoEncoder.encode(source: URL(fileURLWithPath: record.backupPath), destination: output, settings: record.photoSettings!, cancellation: .init())
            record.outputBytes = record.outputPhotoFacts!.bytes
            record.outputFingerprint = try ArchiveIntegrity.fingerprint(output)
            record.stage = .encoded
            return record
        }

        func remove() { environment.remove() }
    }
}
