import Foundation
import CSQLite

public enum SharedLibraryState: String, Codable, Sendable {
    case shared, personal, unknown
    public var title: String { switch self { case .shared: return "Shared"; case .personal: return "Personal"; case .unknown: return "Unknown" } }
}

public struct SharedLibraryObservation: Codable, Equatable, Sendable {
    public let state: SharedLibraryState
    public let checkedAt: Date
    public let libraryID: String?
    public let modelVersion: Int?
    public let detail: String

    public init(state: SharedLibraryState, checkedAt: Date = Date(), libraryID: String? = nil, modelVersion: Int? = nil, detail: String) {
        self.state = state; self.checkedAt = checkedAt; self.libraryID = libraryID; self.modelVersion = modelVersion; self.detail = detail
    }
}

public struct SharedLibraryAssetIdentity: Sendable {
    public let localIdentifier: String
    public let filename: String
    public let isVideo: Bool
    public let creationDate: Date?
    public init(localIdentifier: String, filename: String, isVideo: Bool, creationDate: Date? = nil) {
        self.localIdentifier = localIdentifier; self.filename = filename; self.isVideo = isVideo; self.creationDate = creationDate
    }
}

public struct SharedLibrarySnapshot: Sendable {
    public let observations: [String: SharedLibraryObservation]
    public let libraryID: String
    public let modelVersion: Int
    public let checkedAt: Date
}

/// Native read-only implementation of the participation-state approach described
/// by OSXPhotos. No OSXPhotos code/runtime is bundled. Undocumented fields are
/// advisory, never an authorization to remove an original or proof of cloud sync.
public enum SharedLibraryReader {
    public static func read(library: URL, assets: [SharedLibraryAssetIdentity]) throws -> SharedLibrarySnapshot {
        guard library.isFileURL, library.pathExtension.lowercased() == "photoslibrary" else {
            throw MediaError.invalid("Choose the connected System Photo Library (.photoslibrary package).")
        }
        let database = library.appendingPathComponent("database/Photos.sqlite")
        let connection = try ReadOnlyPhotosDatabase(database)
        try connection.execute("PRAGMA query_only = ON")
        try connection.execute("PRAGMA trusted_schema = OFF")
        try connection.execute("BEGIN")
        defer { try? connection.execute("ROLLBACK") }
        try connection.requireTable("Z_METADATA", columns: ["Z_UUID", "Z_PLIST"])
        try connection.requireTable("ZASSET", columns: ["Z_PK", "ZUUID", "ZFILENAME", "ZKIND", "ZDATECREATED", "ZTRASHEDSTATE", "ZACTIVELIBRARYSCOPEPARTICIPATIONSTATE"])
        try connection.requireTable("ZADDITIONALASSETATTRIBUTES", columns: ["ZASSET", "ZORIGINALFILENAME"])
        let metadata = try connection.prepare("SELECT Z_UUID, Z_PLIST FROM Z_METADATA LIMIT 2")
        defer { sqlite3_finalize(metadata) }
        guard sqlite3_step(metadata) == SQLITE_ROW, let libraryID = string(metadata, 0), UUID(uuidString: libraryID) != nil,
              sqlite3_column_type(metadata, 1) == SQLITE_BLOB, let bytes = sqlite3_column_blob(metadata, 1) else {
            throw MediaError.invalid("Photos database identity/model metadata is unavailable. Sharing stays Unknown.")
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(metadata, 1)))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let model = Int(String(describing: plist["PLModelVersion"] ?? "")),
              (16320...19999).contains(model), sqlite3_step(metadata) == SQLITE_DONE else {
            throw MediaError.invalid("This Photos database model is not supported for sharing detection. Sharing stays Unknown.")
        }
        let query = try connection.prepare("""
            SELECT a.ZACTIVELIBRARYSCOPEPARTICIPATIONSTATE, a.ZKIND,
                   COALESCE(NULLIF(x.ZORIGINALFILENAME, ''), a.ZFILENAME), a.ZDATECREATED, a.ZTRASHEDSTATE
            FROM ZASSET a LEFT JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK
            WHERE a.ZUUID IN (?, ?) LIMIT 2
            """)
        defer { sqlite3_finalize(query) }
        let now = Date()
        var result: [String: SharedLibraryObservation] = [:]
        for asset in assets {
            try Task.checkCancellation()
            func observed(_ state: SharedLibraryState, _ detail: String) -> SharedLibraryObservation {
                SharedLibraryObservation(state: state, checkedAt: now, libraryID: libraryID, modelVersion: model, detail: detail)
            }
            result[asset.localIdentifier] = observed(.unknown, "The asset could not be matched in the selected library.")
            guard let id = uuid(from: asset.localIdentifier), !asset.filename.isEmpty else { continue }
            sqlite3_reset(query); sqlite3_clear_bindings(query)
            try connection.bind(id, to: query, at: 1); try connection.bind(id.lowercased(), to: query, at: 2)
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { continue }
            guard step == SQLITE_ROW else { throw connection.failure() }
            guard sqlite3_column_type(query, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(query, 1) == SQLITE_INTEGER,
                  sqlite3_column_type(query, 4) == SQLITE_INTEGER,
                  sqlite3_column_int(query, 4) == 0,
                  sqlite3_column_int(query, 1) == (asset.isVideo ? 1 : 0),
                  string(query, 2)?.precomposedStringWithCanonicalMapping == asset.filename.precomposedStringWithCanonicalMapping else { continue }
            if let creation = asset.creationDate {
                guard sqlite3_column_type(query, 3) != SQLITE_NULL,
                      abs(sqlite3_column_double(query, 3) - creation.timeIntervalSinceReferenceDate) < 1 else { continue }
            }
            let participation = sqlite3_column_int64(query, 0)
            guard participation >= 0 else { continue }
            // Follow OSXPhotos' bool(active_library_participation_state)
            // interpretation only within the explicitly supported model range.
            let state: SharedLibraryState = participation == 0 ? .personal : .shared
            let detail = "Inferred from selected-library database flag \(participation). Undocumented metadata can be stale; this does not verify iCloud synchronization."
            guard sqlite3_step(query) == SQLITE_DONE else {
                result[asset.localIdentifier] = observed(.unknown, "The database returned an ambiguous asset match.")
                continue
            }
            result[asset.localIdentifier] = observed(state, detail)
        }
        return SharedLibrarySnapshot(observations: result, libraryID: libraryID, modelVersion: model, checkedAt: now)
    }

    public static func uuid(from identifier: String) -> String? {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, let uuid = UUID(uuidString: String(first)),
              parts.count == 1 || (parts.count == 3 && parts[1] == "L0" && !parts[2].isEmpty && parts[2].allSatisfy(\.isNumber)) else { return nil }
        return uuid.uuidString
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
}

private final class ReadOnlyPhotosDatabase {
    private var handle: OpaquePointer?
    init(_ url: URL) throws {
        let code = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let handle, sqlite3_db_readonly(handle, "main") == 1 else {
            let error = failure(); if let handle { sqlite3_close(handle) }; self.handle = nil; throw error
        }
        sqlite3_busy_timeout(handle, 1500)
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func failure() -> MediaError {
        let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Could not open database"
        return .invalid("Read-only sharing detection failed: \(message). No Photos data was edited; sharing stays Unknown.")
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else { throw failure() }
    }
    func requireTable(_ name: String, columns required: Set<String>) throws {
        let table = try prepare("SELECT type FROM sqlite_master WHERE name = ?")
        defer { sqlite3_finalize(table) }
        try bind(name, to: table, at: 1)
        guard sqlite3_step(table) == SQLITE_ROW, let type = sqlite3_column_text(table, 0), String(cString: type) == "table" else {
            throw MediaError.invalid("The selected Photos database schema is unsupported. Sharing stays Unknown.")
        }
        let statement = try prepare("PRAGMA table_info('\(name)')") // names are fixed constants above
        defer { sqlite3_finalize(statement) }
        var available = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { if let value = sqlite3_column_text(statement, 1) { available.insert(String(cString: value)) } }
        guard required.isSubset(of: available) else { throw MediaError.invalid("Required sharing metadata columns are missing. Sharing stays Unknown.") }
    }
}
