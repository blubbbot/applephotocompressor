import SwiftUI
import CompressionCore

extension CompressionSettings {
    var pictureQualityExplanation: String {
        if useCustomBitrate {
            return "Your bitrate sets the video data per second. Lower values can blur fine detail or create blocks in complex scenes and motion."
        }
        switch quality {
        case .smaller: return "Uses less data per frame. Fine textures and fast motion are more likely to look softer or show compression artifacts."
        case .balanced: return "Balances file size and picture detail. Fine textures, gradients, and motion can still change."
        case .higher: return "Uses more data to retain more picture detail. Files are usually larger, and encoding is still lossy."
        }
    }
}

struct CompressionImpactView: View {
    let video: LibraryVideo
    let settings: CompressionSettings
    let reviewingFinishedCopy: Bool

    private var plan: CompressionPlan { CompressionPlan(facts: video.facts, settings: settings) }
    private var reducesResolution: Bool { plan.width < video.facts.width || plan.height < video.facts.height }
    private var reducesFrameRate: Bool { plan.frameRate < video.facts.frameRate - 0.1 }

    var summary: String {
        let dimensions = reducesResolution ? "\(video.facts.width) × \(video.facts.height) → \(plan.width) × \(plan.height)" : "same pixel dimensions"
        let motion: String
        if video.hasInspectedFacts {
            motion = reducesFrameRate ? "\(fps(video.facts.frameRate)) → \(fps(plan.frameRate)) fps" : "same frame rate"
        } else {
            motion = settings.frameRate.limit.map { "up to \(fps($0)) fps" } ?? "original frame rate"
        }
        return "Lossy HEVC · \(dimensions) · \(motion) · audio unchanged"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("What changes").font(.headline)
                Spacer()
                Text(reviewingFinishedCopy ? "Settings used for this copy" : "With your current settings")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Every copy is re-encoded as HEVC with some loss of picture detail. Keeping the original resolution and frame rate does not make compression lossless.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)

            impactRow("Picture dimensions", symbol: "arrow.down.right.and.arrow.up.left",
                value: "\(video.facts.width) × \(video.facts.height) → \(plan.width) × \(plan.height)",
                explanation: resolutionExplanation, changes: reducesResolution)

            impactRow("Motion", symbol: "film", value: frameRateSummary,
                explanation: frameRateExplanation, changes: video.hasInspectedFacts && reducesFrameRate)

            impactRow("Picture encoding", symbol: "slider.horizontal.3",
                value: "HEVC · \(settings.useCustomBitrate ? "Custom" : settings.quality.rawValue) · \(video.hasInspectedFacts ? "target" : "planning target") \(String(format: "%.2f", Double(plan.videoBitrate) / 1_000_000)) Mbps",
                explanation: encodingExplanation, changes: true)

            impactRow("Color and HDR", symbol: "sun.max", value: colorSummary,
                explanation: colorExplanation, changes: false)

            impactRow("Sound and duration", symbol: "waveform", value: "Retained",
                explanation: "Audio is copied without re-encoding. The clip keeps its duration and playback speed, including when the frame rate is reduced.", changes: false)

            Divider()
            Text("The estimate uses target bitrate and duration. Actual savings depend on the video; they cannot be split reliably into a percentage for each setting or used as a visual quality score. Compare the original and compressed previews before deleting an original.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }

    private func impactRow(_ title: String, symbol: String, value: String, explanation: String, changes: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(changes ? Color.orange : Color.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.medium))
                Text(explanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var resolutionExplanation: String {
        guard reducesResolution else { return "The pixel dimensions stay the same. Lossy encoding can still change fine detail." }
        let originalPixels = Double(max(1, video.facts.width)) * Double(max(1, video.facts.height))
        let removed = Int((1 - Double(plan.width * plan.height) / originalPixels) * 100)
        return "\(removed)% fewer pixels. Scaling down removes fine detail and leaves less room to zoom or crop later."
    }

    private var encodingExplanation: String {
        var text = settings.pictureQualityExplanation + " A more efficient codec can also save space. Videos already in HEVC are re-encoded too; savings can still involve discarded detail."
        if let bytes = video.facts.bytes, video.facts.duration > 0 {
            let originalMbps = Double(bytes) * 8 / video.facts.duration / 1_000_000
            text += " Original file average: \(String(format: "%.2f", originalMbps)) Mbps including sound. The target above is video only."
        }
        return text
    }

    private func fps(_ value: Double) -> String { String(format: value.rounded() == value ? "%.0f" : "%.2f", value) }

    private var frameRateSummary: String {
        guard video.hasInspectedFacts else {
            return settings.frameRate.limit.map { "Up to \(fps($0)) fps · source not inspected yet" } ?? "Keep the original frame rate"
        }
        return "\(fps(video.facts.frameRate)) → \(fps(plan.frameRate)) fps"
    }

    private var frameRateExplanation: String {
        guard video.hasInspectedFacts else {
            let policy = settings.frameRate == .original ? "Original keeps the source frame rate." : "Frames are removed only when the source exceeds your chosen cap."
            return policy + " Use Inspect original above to check the actual rate now; an iCloud download needs your confirmation. The planning estimate currently assumes 30 fps until inspection."
        }
        if reducesFrameRate {
            return "Fewer moments are kept each second, so fast motion can look less smooth. The video does not become shorter or play faster."
        }
        return "The source frame rate is kept; your cap does not add frames to slower footage."
    }

    private var colorSummary: String {
        guard video.hasInspectedFacts else { return "Checked before encoding" }
        return video.facts.isHDR ? "HDR → 10-bit HDR" : "SDR → SDR"
    }

    private var colorExplanation: String {
        guard video.hasInspectedFacts else {
            return "Use Inspect original to check HDR/SDR before compression. Supported HDR is kept in 10-bit HEVC. Exact Dolby Vision metadata fidelity is not verified."
        }
        return video.facts.isHDR ? "Supported HLG/PQ HDR is preserved. Dolby Vision dynamic metadata may change; exact Dolby Vision fidelity is not verified." : "The copy keeps standard dynamic range. No HDR is added."
    }
}
