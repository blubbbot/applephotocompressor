import XCTest
@testable import CompressionCore

final class PhotoTypeAndSpaceTests: XCTestCase {
    func testPhotoTypesUseIndependentSubtypeFlags() {
        XCTAssertTrue(PhotoTypeFilter.all.includes(isLivePhoto: false, isPanorama: false))
        XCTAssertTrue(PhotoTypeFilter.livePhotos.includes(isLivePhoto: true, isPanorama: false))
        XCTAssertFalse(PhotoTypeFilter.livePhotos.includes(isLivePhoto: false, isPanorama: true))
        XCTAssertTrue(PhotoTypeFilter.panoramas.includes(isLivePhoto: false, isPanorama: true))
        XCTAssertFalse(PhotoTypeFilter.panoramas.includes(isLivePhoto: true, isPanorama: false))
        XCTAssertTrue(PhotoTypeFilter.panoramas.includes(isLivePhoto: true, isPanorama: true))
    }

    func testSourcePanoramaAndLiveTypeSurviveConversionAndJournalReload() throws {
        var record = OperationRecord(sourceID: "original", sourceName: "photo.heic", backupPath: "/original", outputPath: "/copy", settings: CompressionSettings())
        let legacy = try JSONDecoder().decode(OperationRecord.self, from: JSONEncoder().encode(record))
        XCTAssertNil(legacy.sourceIsPanorama)
        record.sourceIsPanorama = true; record.mediaKind = .livePhoto
        var settings = PhotoCompressionSettings(); settings.convertLiveToStill = true; record.photoSettings = settings
        let decoded = try JSONDecoder().decode(OperationRecord.self, from: JSONEncoder().encode(record))
        XCTAssertFalse(decoded.outputIsLivePhoto)
        XCTAssertTrue(PhotoTypeFilter.livePhotos.includes(isLivePhoto: decoded.kind == .livePhoto, isPanorama: decoded.sourceIsPanorama == true))
        XCTAssertTrue(PhotoTypeFilter.panoramas.includes(isLivePhoto: decoded.kind == .livePhoto, isPanorama: decoded.sourceIsPanorama == true))
    }

    func testDiskWarningsIncludeSelectionWorkingSpaceAndUnknownCapacity() {
        XCTAssertEqual(DiskSpaceLevel.assess(available: nil, required: 20_000_000_000), .normal, "Unknown capacity must not be presented as measured low space")
        XCTAssertEqual(DiskSpaceLevel.assess(available: 50_000_000_000, required: 0), .normal)
        XCTAssertEqual(DiskSpaceLevel.assess(available: 9_999_999_999, required: 0), .low)
        XCTAssertEqual(DiskSpaceLevel.assess(available: 1_999_999_999, required: 0), .critical)
        XCTAssertEqual(DiskSpaceLevel.assess(available: 20_000_000_000, required: 25_000_000_000), .low)
        XCTAssertEqual(DiskSpaceLevel.assess(available: 0, required: 0), .critical)
    }
}
