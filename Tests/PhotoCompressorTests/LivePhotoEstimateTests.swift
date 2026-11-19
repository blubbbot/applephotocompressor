import XCTest
import CompressionCore
@testable import PhotoCompressor

final class LivePhotoEstimateTests: XCTestCase {
    func testMeasuredMotionIsUnchangedWhileQualityAndResolutionAffectStill() {
        let live = photo(motion: 4_000_000)
        var settings = PhotoCompressionSettings()
        let original = estimate(live, settings)
        XCTAssertEqual(original, 7_900_000) // 6 MB JPEG × 0.65 + 4 MB motion.
        settings.quality = 0.4
        XCTAssertLessThan(estimate(live, settings), original)
        settings.quality = 0.8; settings.resolution = .small
        XCTAssertLessThan(estimate(live, settings), original)
        XCTAssertGreaterThan(estimate(live, settings), 4_000_000)
        let retained = estimate(live, settings)
        settings.convertLiveToStill = true
        XCTAssertEqual(retained - estimate(live, settings), 4_000_000)
    }

    func testUnknownMotionUsesProvisionalSplitAndCanMeetDefaultRecommendationThreshold() {
        let live = photo(motion: nil)
        var settings = PhotoCompressionSettings()
        let original = estimate(live, settings)
        XCTAssertEqual(original, 8_250_000)
        XCTAssertGreaterThanOrEqual(Double(10_000_000 - original) / 10_000_000, settings.minimumSavings)
        settings.resolution = .small
        XCTAssertLessThan(estimate(live, settings), original)
        settings.convertLiveToStill = true
        XCTAssertEqual(estimate(live, settings), 748_800)
    }

    func testExistingHEICAndOrdinaryPhotosKeepTheirOwnEstimates() {
        var live = photo(motion: 9_000_000); live.photoFormat = "public.heic"
        XCTAssertEqual(estimate(live, .init()), 9_900_000)
        live.kind = .photo
        XCTAssertEqual(estimate(live, .init()), 9_000_000)
    }

    private func photo(motion: Int64?) -> LibraryVideo {
        LibraryVideo(id: "live", name: "photo.jpg", asset: nil, fileURL: nil,
                     facts: .init(width: 4000, height: 3000, duration: 0, bytes: 10_000_000), date: .distantPast,
                     unsupportedReason: nil, kind: .livePhoto, photoFormat: "public.jpeg", pairedVideoBytes: motion)
    }
    private func estimate(_ photo: LibraryVideo, _ settings: PhotoCompressionSettings) -> Int64 {
        LibraryListIndex.estimatedBytes(photo, settings: .init(), photoSettings: settings)
    }
}
