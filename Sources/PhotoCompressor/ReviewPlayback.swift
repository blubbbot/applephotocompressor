import AVKit
import CompressionCore

@MainActor
final class ReviewPlayback: ObservableObject {
    @Published var original: AVPlayer?
    @Published var compressed: AVPlayer?
    @Published var originalFacts: VideoFacts?
    @Published var compressedFacts: VideoFacts?
    @Published var originalError: String?
    @Published var compressedError: String?
    @Published var loading = false
    @Published var elapsed = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var scrubbing = false
    @Published var audio: ReviewAudio = .original { didSet { updateAudio() } }
    private var loadID = UUID()
    private var seekID = UUID()
    private var seekTask: Task<Void, Never>?
    private var resumeAfterScrubbing = false

    var canCompare: Bool { original != nil && compressed != nil && duration > 0 }

    func load(_ record: OperationRecord) async {
        stop()
        let token = UUID(); loadID = token
        original = nil; compressed = nil; originalFacts = nil; compressedFacts = nil
        originalError = nil; compressedError = nil; elapsed = 0; duration = 0; scrubbing = false; loading = true
        defer { if loadID == token { loading = false } }
        do {
            let info = try await VideoEncoder.inspect(URL(fileURLWithPath: record.backupPath))
            guard !Task.isCancelled, loadID == token else { return }
            originalFacts = info.facts
            original = AVPlayer(url: URL(fileURLWithPath: record.backupPath))
        } catch {
            guard !Task.isCancelled, loadID == token else { return }
            originalError = "Original archive unavailable. Connect its disk or locate the archive in Finder. \(error.localizedDescription)"
        }
        do {
            let info = try await VideoEncoder.inspect(URL(fileURLWithPath: record.outputPath))
            guard !Task.isCancelled, loadID == token else { return }
            compressedFacts = info.facts
            compressed = AVPlayer(url: URL(fileURLWithPath: record.outputPath))
        } catch {
            guard !Task.isCancelled, loadID == token else { return }
            compressedError = "Compressed archive unavailable. Connect its disk or locate the archive in Finder. \(error.localizedDescription)"
        }
        guard !Task.isCancelled, loadID == token else { return }
        duration = min(originalFacts?.duration ?? 0, compressedFacts?.duration ?? 0)
        updateAudio()
    }

    func pause() {
        original?.pause(); compressed?.pause(); playing = false
    }

    func stop() {
        seekID = UUID(); seekTask?.cancel(); seekTask = nil; pause()
    }

    func togglePlayback() {
        guard canCompare else { return }
        if playing { stop() }
        else { seek(to: elapsed >= duration - 0.05 ? 0 : elapsed, resume: true) }
    }

    func editPosition(_ editing: Bool) {
        if editing {
            resumeAfterScrubbing = playing; stop(); scrubbing = true
        } else {
            scrubbing = false; seek(to: elapsed, resume: resumeAfterScrubbing)
        }
    }

    func step(_ direction: Double) {
        stop()
        let fps = max(originalFacts?.frameRate ?? 30, compressedFacts?.frameRate ?? 30, 1)
        seek(to: elapsed + direction / fps, resume: false)
    }

    func synchronize() {
        guard !scrubbing, seekTask == nil, let original, let compressed else { return }
        let seconds = original.currentTime().seconds
        if seconds.isFinite { elapsed = min(max(seconds, 0), duration) }
        if playing, elapsed >= duration - 0.02 { pause(); return }
        // Keep long comparisons aligned if the two playback clocks drift.
        if playing, original.rate > 0, compressed.rate > 0 {
            let other = compressed.currentTime().seconds
            if other.isFinite, abs(seconds - other) > 0.10 { seek(to: elapsed, resume: true) }
        }
    }

    private func seek(to seconds: Double, resume: Bool) {
        guard canCompare, let original, let compressed else { return }
        seekTask?.cancel(); pause()
        let token = UUID(); seekID = token
        elapsed = min(max(seconds, 0), max(0, duration - 0.001))
        let time = CMTime(seconds: elapsed, preferredTimescale: 60_000)
        seekTask = Task {
            async let first = original.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            async let second = compressed.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            let finished = await (first, second)
            guard !Task.isCancelled, seekID == token else { return }
            seekTask = nil
            if resume && finished.0 && finished.1 {
                let hostTime = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.15, preferredTimescale: 60_000))
                original.setRate(1, time: time, atHostTime: hostTime)
                compressed.setRate(1, time: time, atHostTime: hostTime)
                playing = true
            }
        }
    }

    private func updateAudio() {
        original?.isMuted = audio != .original
        compressed?.isMuted = audio != .compressed
    }
}

enum ReviewAudio: String, CaseIterable, Identifiable {
    case original = "Original audio", compressed = "Compressed audio", muted = "Muted"
    var id: Self { self }
}
