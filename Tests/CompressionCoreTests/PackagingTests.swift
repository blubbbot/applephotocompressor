import XCTest

final class PackagingTests: XCTestCase {
    func testAppDeclaresRequiredPrivacyPurposeStrings() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: project.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        for key in ["NSPhotoLibraryUsageDescription", "NSAppleEventsUsageDescription"] {
            let purpose = try XCTUnwrap(plist[key] as? String, "Missing privacy purpose string: \(key)")
            XCTAssertFalse(purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty privacy purpose string: \(key)")
        }
        XCTAssertNil(plist["NSPhotosUsageDescription"], "The misspelled key is ignored by macOS and does not authorize Photos access.")
    }
}
