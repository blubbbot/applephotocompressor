import Foundation

public enum PhotoType: String, CaseIterable, Identifiable, Sendable {
    case normal, livePhotos, panoramas
    public var id: Self { self }
    public var title: String {
        switch self {
        case .normal: return "Normal photos"
        case .livePhotos: return "Live Photos"
        case .panoramas: return "Panoramas"
        }
    }
}

public struct PhotoTypeFilter: RawRepresentable, Equatable, Sendable {
    public var types: Set<PhotoType>
    public init(types: Set<PhotoType>) { self.types = types }
    public static let all = Self(types: Set(PhotoType.allCases))
    public static let normal = Self(types: [.normal])
    public static let livePhotos = Self(types: [.livePhotos])
    public static let panoramas = Self(types: [.panoramas])
    public var title: String {
        if self == .all { return "All photos" }
        if types.isEmpty { return "No photo types" }
        if types.count == 1 { return types.first!.title }
        return "\(types.count) photo types"
    }
    public var rawValue: String { PhotoType.allCases.filter(types.contains).map(\.rawValue).joined(separator: ",") }
    public init?(rawValue: String) {
        // Migrate the single-choice preference used by 0.2.4.
        if rawValue == "all" { self = .all; return }
        if rawValue.isEmpty { self.init(types: []); return }
        let parts = rawValue.split(separator: ",", omittingEmptySubsequences: false)
        let decoded = parts.compactMap { PhotoType(rawValue: String($0)) }
        guard parts.count == decoded.count else { return nil }
        self.init(types: Set(decoded))
    }
    public func includes(isLivePhoto: Bool, isPanorama: Bool?) -> Bool {
        // Older Review records have no panorama flag. All includes them;
        // Normal must not silently classify an unknown panorama as ordinary.
        if self == .all { return true }
        return (!isLivePhoto && isPanorama == false && types.contains(.normal)) ||
        (isLivePhoto && types.contains(.livePhotos)) || (isPanorama == true && types.contains(.panoramas))
    }
}
