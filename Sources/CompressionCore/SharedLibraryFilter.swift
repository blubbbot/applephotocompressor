import Foundation

public enum LibrarySharingFilter: String, CaseIterable, Identifiable {
    case all, shared, personal, unknown
    public var id: Self { self }
    public var title: String {
        switch self {
        case .all: return "All libraries"
        case .shared: return "Shared Library"
        case .personal: return "Personal Library"
        case .unknown: return "Unknown"
        }
    }
    public func includes(_ state: SharedLibraryState) -> Bool {
        switch self {
        case .all: return true
        case .shared: return state == .shared
        case .personal: return state == .personal
        case .unknown: return state == .unknown
        }
    }
}

public enum ReviewSharingFilter: String, CaseIterable, Identifiable {
    case all, shared, personal, unknown, needsSharing
    public var id: Self { self }
    public var title: String {
        switch self {
        case .all: return "All libraries"
        case .shared: return "Shared originals"
        case .personal: return "Personal originals"
        case .unknown: return "Unknown originals"
        case .needsSharing: return "Needs re-sharing"
        }
    }
    public func includes(original: SharedLibraryState, replacement: SharedLibraryState, hasPhotosTarget: Bool) -> Bool {
        switch self {
        case .all: return true
        case .shared: return original == .shared
        case .personal: return original == .personal
        case .unknown: return original == .unknown
        case .needsSharing: return original == .shared && replacement != .shared && hasPhotosTarget
        }
    }
}
