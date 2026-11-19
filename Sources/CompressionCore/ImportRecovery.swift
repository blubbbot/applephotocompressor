import Foundation

public struct ImportedCopy: Sendable {
    public let id: String
    public let modifiedAt: Date?

    public init(id: String, modifiedAt: Date?) {
        self.id = id; self.modifiedAt = modifiedAt
    }
}

public enum ImportRecovery {
    // Returns true when an existing copy was reused. Mutate the caller's record
    // before each save, so its error handler cannot erase an import checkpoint.
    public static func ensureImported(
        _ record: inout OperationRecord,
        findExisting: (String) async throws -> String?,
        create: () async throws -> ImportedCopy,
        persist: (OperationRecord) async throws -> Void
    ) async throws -> Bool {
        if record.replacementID != nil { return true }
        if record.importAttempted == true,
           let id = try await findExisting(URL(fileURLWithPath: record.outputPath).lastPathComponent) {
            record.replacementID = id; record.stage = .imported
            try await persist(record)
            return true
        }
        record.importAttempted = true
        try await persist(record)
        let copy = try await create()
        record.replacementID = copy.id; record.replacementModifiedAt = copy.modifiedAt; record.stage = .imported
        try await persist(record)
        return false
    }
}
