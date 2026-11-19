import XCTest
@testable import CompressionCore

final class ImportRecoveryTests: XCTestCase {
    private enum Failure: Error { case journalWrite, callbackLost }

    func testImportSucceededBeforeJournalWriteFailureDoesNotCreateDuplicateOnRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try OperationJournal(url: directory.appendingPathComponent("operations.json"))
        var record = OperationRecord(sourceID: "original", sourceName: "original.mov", backupPath: "archive", outputPath: "/archive/unique-copy.mov", settings: .init())
        record.stage = .encoded
        var imports = 0
        do {
            _ = try await ImportRecovery.ensureImported(&record, findExisting: { _ in XCTFail("No previous attempt"); return nil }, create: {
                imports += 1
                let checkpoint = await journal.all().first
                XCTAssertEqual(checkpoint?.importAttempted, true)
                XCTAssertNil(checkpoint?.replacementID)
                return ImportedCopy(id: "created-copy", modifiedAt: nil)
            }, persist: { update in
                if update.replacementID != nil { throw Failure.journalWrite }
                try await journal.save(update)
            })
            XCTFail("Expected injected failure")
        } catch { XCTAssertTrue(error is Failure) }
        // The caller can also checkpoint the known ID in its error handler.
        XCTAssertEqual(record.replacementID, "created-copy")
        XCTAssertEqual(record.importAttempted, true)
        let reopened = try OperationJournal(url: directory.appendingPathComponent("operations.json"))
        let reopenedRecords = await reopened.all()
        var recovered = try XCTUnwrap(reopenedRecords.first)
        let reused = try await ImportRecovery.ensureImported(&recovered, findExisting: { name in
            XCTAssertEqual(name, "unique-copy.mov")
            return "created-copy"
        }, create: { imports += 1; return ImportedCopy(id: "duplicate", modifiedAt: nil) }, persist: { try await reopened.save($0) })
        XCTAssertTrue(reused)
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(recovered.replacementID, "created-copy")
        XCTAssertEqual(recovered.stage, .imported)
    }

    func testLostCallbackRecoversByFilenameAndKnownIDNeverReimports() async throws {
        var record = OperationRecord(sourceID: "original", sourceName: "original.mov", backupPath: "archive", outputPath: "/archive/unique.mov", settings: .init())
        var imported = false
        do {
            _ = try await ImportRecovery.ensureImported(&record, findExisting: { _ in nil }, create: {
                imported = true; throw Failure.callbackLost
            }, persist: { _ in })
            XCTFail("Expected injected failure")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertTrue(imported); XCTAssertTrue(record.importAttempted == true); XCTAssertNil(record.replacementID)
        _ = try await ImportRecovery.ensureImported(&record, findExisting: { _ in "existing" }, create: {
            XCTFail("Must reuse successful import"); return ImportedCopy(id: "duplicate", modifiedAt: nil)
        }, persist: { _ in })
        _ = try await ImportRecovery.ensureImported(&record, findExisting: { _ in XCTFail("Already have ID"); return nil }, create: {
            XCTFail("Must not recreate a missing or changed known copy"); return ImportedCopy(id: "duplicate", modifiedAt: nil)
        }, persist: { _ in })
        XCTAssertEqual(record.replacementID, "existing")
    }

    func testFailedCheckpointPreventsImport() async throws {
        var record = OperationRecord(sourceID: "original", sourceName: "original.mov", backupPath: "archive", outputPath: "output", settings: .init())
        do {
            _ = try await ImportRecovery.ensureImported(&record, findExisting: { _ in nil }, create: {
                XCTFail("Import must wait for a durable checkpoint"); return ImportedCopy(id: "copy", modifiedAt: nil)
            }, persist: { _ in throw Failure.journalWrite })
            XCTFail("Expected injected failure")
        } catch { XCTAssertTrue(error is Failure) }
    }
}
