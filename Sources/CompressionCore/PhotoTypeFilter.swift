import Foundation

public enum PhotoTypeFilter: String, CaseIterable, Identifiable {
    case all, livePhotos, panoramas
    public var id: Self { self }
    public var title: String {
        switch self {
        case .all: return "All photos"
        case .livePhotos: return "Live Photos"
        case .panoramas: return "Panoramas"
        }
    }
    public func includes(isLivePhoto: Bool, isPanorama: Bool) -> Bool {
        switch self {
        case .all: return true
        case .livePhotos: return isLivePhoto
        case .panoramas: return isPanorama
        }
    }
}
