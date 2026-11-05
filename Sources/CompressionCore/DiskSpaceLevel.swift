import Foundation

public enum DiskSpaceLevel: Int, Comparable {
    case normal, low, critical
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public static func assess(available: Int64?, required: Int64) -> Self {
        guard let available else { return .normal }
        if available < 2_000_000_000 { return .critical }
        if available < 10_000_000_000 || required > available { return .low }
        return .normal
    }
}
