import XCTest
import CSQLite
@testable import CompressionCore

final class SharedLibraryReaderTests: XCTestCase {
    private let assetID = "12345678-1234-4321-ABCD-123456789ABC"
    private let libraryID = "87654321-4321-4321-ABCD-123456789ABC"
    private let creation = Date(timeIntervalSinceReferenceDate: 123456)

    func testSharedPersonalAndUnknownAndOriginalFilenameMatching() throws {
        let fixture = try database()
        defer { fixture.close() }
        try fixture.exec("INSERT INTO ZASSET VALUES (1, '\(assetID)', 'internal.mov', 1, 123456, 0, 1)")
        try fixture.exec("INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (1, 'original.mov')")
        let identity = asset()
        let shared = try SharedLibraryReader.read(library: fixture.library, assets: [identity])
        XCTAssertEqual(shared.libraryID, libraryID)
        XCTAssertEqual(shared.modelVersion, 18201)
        XCTAssertEqual(shared.observations[identity.localIdentifier]?.state, .shared)
        XCTAssertEqual(shared.observations[identity.localIdentifier]?.checkedAt, shared.checkedAt)
        try fixture.exec("UPDATE ZASSET SET ZACTIVELIBRARYSCOPEPARTICIPATIONSTATE = 0")
        XCTAssertEqual(try state(fixture, identity), .personal)
        try fixture.exec("UPDATE ZASSET SET ZACTIVELIBRARYSCOPEPARTICIPATIONSTATE = NULL")
        XCTAssertEqual(try state(fixture, identity), .unknown, "A NULL flag must never be interpreted as Personal")
        try fixture.exec("UPDATE ZASSET SET ZACTIVELIBRARYSCOPEPARTICIPATIONSTATE = -1")
        XCTAssertEqual(try state(fixture, identity), .unknown)
    }

    func testIdentityTypeDateTrashAndDuplicateMismatchesStayUnknown() throws {
        let fixture = try database()
        defer { fixture.close() }
        try fixture.exec("INSERT INTO ZASSET VALUES (1, '\(assetID.lowercased())', 'original.mov', 1, 123456, 0, 2)")
        XCTAssertEqual(try state(fixture, asset()), .shared, "Lowercase database UUIDs must match the public local identifier")
        XCTAssertEqual(try state(fixture, asset(filename: "another.mov")), .unknown)
        XCTAssertEqual(try state(fixture, asset(video: false)), .unknown)
        XCTAssertEqual(try state(fixture, asset(date: creation.addingTimeInterval(20))), .unknown)
        XCTAssertEqual(try state(fixture, asset(id: UUID().uuidString)), .unknown)
        try fixture.exec("UPDATE ZASSET SET ZTRASHEDSTATE = 1")
        XCTAssertEqual(try state(fixture, asset()), .unknown)
        try fixture.exec("UPDATE ZASSET SET ZTRASHEDSTATE = 0")
        try fixture.exec("INSERT INTO ZASSET SELECT 2, ZUUID, ZFILENAME, ZKIND, ZDATECREATED, ZTRASHEDSTATE, ZACTIVELIBRARYSCOPEPARTICIPATIONSTATE FROM ZASSET")
        XCTAssertEqual(try state(fixture, asset()), .unknown)
    }

    func testUnsupportedSchemaAndModelAreRejected() throws {
        for model in [16319, 20000, 270000000] {
            let fixture = try database(model: model)
            defer { fixture.close() }
            XCTAssertThrowsError(try SharedLibraryReader.read(library: fixture.library, assets: [asset()]))
        }
        let fixture = try database()
        defer { fixture.close() }
        try fixture.exec("ALTER TABLE ZASSET RENAME COLUMN ZACTIVELIBRARYSCOPEPARTICIPATIONSTATE TO CHANGED")
        XCTAssertThrowsError(try SharedLibraryReader.read(library: fixture.library, assets: [asset()]))
    }

    func testReadsCommittedWALAndDoesNotEditDatabaseContents() throws {
        let fixture = try database()
        defer { fixture.close() }
        try fixture.exec("PRAGMA journal_mode = WAL")
        try fixture.exec("INSERT INTO ZASSET VALUES (1, '\(assetID)', 'original.mov', 1, 123456, 0, 1)")
        let database = fixture.library.appendingPathComponent("database/Photos.sqlite")
        let before = try Data(contentsOf: database)
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let beforeWAL = try Data(contentsOf: wal)
        XCTAssertEqual(try state(fixture, asset()), .shared)
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(try Data(contentsOf: wal), beforeWAL)
        try fixture.exec("UPDATE ZASSET SET ZACTIVELIBRARYSCOPEPARTICIPATIONSTATE = 0")
        XCTAssertEqual(try state(fixture, asset()), .personal, "Do not use immutable mode: committed WAL updates must be visible")
    }

    func testMissingDatabaseIsNotCreatedAndIdentifierParsingIsStrict() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".photoslibrary")
        XCTAssertThrowsError(try SharedLibraryReader.read(library: library, assets: [asset()]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertEqual(SharedLibraryReader.uuid(from: assetID + "/L0/001"), assetID)
        XCTAssertEqual(SharedLibraryReader.uuid(from: assetID.lowercased()), assetID)
        for invalid in ["original", assetID + "/L1/001", assetID + "/L0/", assetID + "/L0/001/extra"] {
            XCTAssertNil(SharedLibraryReader.uuid(from: invalid))
        }
    }

    func testObservationPersistsAndLegacyJournalKeepsUnknown() throws {
        var record = OperationRecord(sourceID: assetID, sourceName: "original.mov", backupPath: "/original", outputPath: "/copy", settings: CompressionSettings())
        let legacy = try JSONDecoder().decode(OperationRecord.self, from: JSONEncoder().encode(record))
        XCTAssertNil(legacy.sourceSharedLibrary)
        XCTAssertFalse(legacy.requiresSharedLibraryReview)
        record.sourceSharedLibrary = SharedLibraryObservation(state: .shared, checkedAt: creation, libraryID: libraryID, modelVersion: 18201, detail: "Fixture")
        let reopened = try JSONDecoder().decode(OperationRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(reopened.sourceSharedLibrary, record.sourceSharedLibrary)
        XCTAssertTrue(reopened.requiresSharedLibraryReview)
    }

    private func state(_ fixture: Fixture, _ identity: SharedLibraryAssetIdentity) throws -> SharedLibraryState? {
        try SharedLibraryReader.read(library: fixture.library, assets: [identity]).observations[identity.localIdentifier]?.state
    }
    private func asset(id: String? = nil, filename: String = "original.mov", video: Bool = true, date: Date? = nil) -> SharedLibraryAssetIdentity {
        SharedLibraryAssetIdentity(localIdentifier: (id ?? assetID) + "/L0/001", filename: filename, isVideo: video, creationDate: date ?? creation)
    }
    private func database(model: Int = 18201) throws -> Fixture {
        let fixture = try Fixture()
        try fixture.exec("CREATE TABLE Z_METADATA (Z_UUID TEXT, Z_PLIST BLOB)")
        try fixture.exec("CREATE TABLE ZASSET (Z_PK INTEGER, ZUUID TEXT, ZFILENAME TEXT, ZKIND INTEGER, ZDATECREATED REAL, ZTRASHEDSTATE INTEGER, ZACTIVELIBRARYSCOPEPARTICIPATIONSTATE INTEGER)")
        try fixture.exec("CREATE TABLE ZADDITIONALASSETATTRIBUTES (ZASSET INTEGER, ZORIGINALFILENAME TEXT)")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["PLModelVersion": model], format: .binary, options: 0)
        let hex = plist.map { String(format: "%02x", $0) }.joined()
        try fixture.exec("INSERT INTO Z_METADATA VALUES ('\(libraryID)', X'\(hex)')")
        return fixture
    }
    private final class Fixture {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".photoslibrary")
        var handle: OpaquePointer?
        init() throws {
            try FileManager.default.createDirectory(at: library.appendingPathComponent("database"), withIntermediateDirectories: true)
            guard sqlite3_open(library.appendingPathComponent("database/Photos.sqlite").path, &handle) == SQLITE_OK else { throw MediaError.invalid("Fixture open failed") }
        }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw MediaError.invalid(String(cString: sqlite3_errmsg(handle))) }
        }
        func close() { if let handle { sqlite3_close(handle); self.handle = nil }; try? FileManager.default.removeItem(at: library) }
        deinit { close() }
    }
}
