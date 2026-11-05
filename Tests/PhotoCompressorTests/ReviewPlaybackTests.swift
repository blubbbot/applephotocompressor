import XCTest
import AVFoundation
import CoreVideo
import VideoToolbox
import CompressionCore
@testable import PhotoCompressor

final class ReviewPlaybackTests: XCTestCase {
    @MainActor
    func testSeekAndFrameSteppingMoveBothPlayers() async throws {
        let (record, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let playback = ReviewPlayback()
        defer { playback.stop() }
        await playback.load(record)
        let ready = await waitUntil { playback.original?.currentItem?.status == .readyToPlay && playback.compressed?.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready, "Both local videos must become ready")
        playback.editPosition(true); playback.elapsed = 1; playback.editPosition(false)
        let sought = await waitUntil { abs((playback.original?.currentTime().seconds ?? -1) - 1) < 0.05 && abs((playback.compressed?.currentTime().seconds ?? -1) - 1) < 0.05 }
        XCTAssertTrue(sought, "Seeking must move both AVPlayer timelines, not just the slider")
        guard sought else { return }
        playback.step(1)
        let stepped = await waitUntil { (playback.original?.currentTime().seconds ?? 0) > 1.02 && (playback.compressed?.currentTime().seconds ?? 0) > 1.02 }
        XCTAssertTrue(stepped, "Frame stepping must move both paused players")
    }

    @MainActor
    func testPlayPauseAndAudioUseActualPlayerState() async throws {
        let (record, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let playback = ReviewPlayback()
        defer { playback.stop() }
        await playback.load(record)
        let ready = await waitUntil { playback.canCompare }
        XCTAssertTrue(ready)
        let original = try XCTUnwrap(playback.original), compressed = try XCTUnwrap(playback.compressed)
        XCTAssertFalse(original.automaticallyWaitsToMinimizeStalling, "Host-clock playback requires automatic waiting to be disabled")
        XCTAssertFalse(compressed.automaticallyWaitsToMinimizeStalling)
        guard !original.automaticallyWaitsToMinimizeStalling, !compressed.automaticallyWaitsToMinimizeStalling else { return }
        playback.togglePlayback()
        let advanced = await waitUntil { original.currentTime().seconds > 0.2 && compressed.currentTime().seconds > 0.2 }
        XCTAssertTrue(advanced, "Play must advance both real players")
        XCTAssertTrue(playback.playing)
        XCTAssertNil(playback.playbackError)
        playback.stop()
        XCTAssertEqual(original.rate, 0); XCTAssertEqual(compressed.rate, 0)
        playback.audio = .compressed
        XCTAssertTrue(original.isMuted); XCTAssertFalse(compressed.isMuted)
        playback.audio = .muted
        XCTAssertTrue(original.isMuted); XCTAssertTrue(compressed.isMuted)
    }

    @MainActor
    func testMissingCopyDisablesComparisonAndReportsTheProblem() async throws {
        var (record, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        record.outputPath = directory.appendingPathComponent("missing.mov").path
        let playback = ReviewPlayback()
        defer { playback.stop() }
        await playback.load(record)
        XCTAssertFalse(playback.canCompare)
        XCTAssertNotNil(playback.compressedError)
        XCTAssertFalse(playback.loading)
    }

    @MainActor
    func testStopAndReloadCancelPendingPlayback() async throws {
        let (record, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let playback = ReviewPlayback()
        defer { playback.stop() }
        await playback.load(record)
        playback.editPosition(true); playback.elapsed = 1; playback.editPosition(false)
        playback.togglePlayback()
        playback.stop()
        await playback.load(record)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(playback.canCompare)
        XCTAssertFalse(playback.playing)
        XCTAssertFalse(playback.preparingPlayback)
        XCTAssertEqual(playback.original?.rate, 0)
        XCTAssertEqual(playback.compressed?.rate, 0)
        XCTAssertEqual(playback.original?.currentTime().seconds ?? -1, 0, accuracy: 0.05)
        XCTAssertEqual(playback.compressed?.currentTime().seconds ?? -1, 0, accuracy: 0.05)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    private func fixture() async throws -> (OperationRecord, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoCompressor-playback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaError.invalid("Cannot generate playback fixture") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData {
                guard writer.status != .failed else { throw writer.error ?? MediaError.invalid("Fixture encoding failed") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var optional: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess, let buffer = optional else { throw MediaError.invalid("Cannot allocate fixture pixels") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 2), CVPixelBufferGetBytesPerRow(buffer) * 180)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? MediaError.invalid("Cannot append fixture frame") }
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaError.invalid("Cannot finish playback fixture") }
        let copy = directory.appendingPathComponent("compressed.mov")
        try FileManager.default.copyItem(at: source, to: copy)
        return (OperationRecord(sourceID: source.path, sourceName: source.lastPathComponent, backupPath: source.path, outputPath: copy.path, settings: CompressionSettings()), directory)
    }
}
