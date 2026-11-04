import SwiftUI

struct VideoInspectionView: View {
    @EnvironmentObject var model: AppModel
    let video: LibraryVideo

    var body: some View {
        if video.isSlowMotion {
            Label("Slo-mo protected · excluded from compression", systemImage: "lock.fill")
                .font(.callout.weight(.medium)).foregroundStyle(.orange)
            Text("Photos identifies this as slow-motion footage. Its captured frames and slow-motion timing are retained by keeping the original.")
                .font(.caption).foregroundStyle(.secondary)
        } else if let reason = video.unsupportedReason {
            Label(reason, systemImage: "lock.fill").font(.callout).foregroundStyle(.orange)
        } else if !video.hasInspectedFacts, video.asset != nil, !video.isDemo {
            VStack(alignment: .leading, spacing: 10) {
                Label("Original video details", systemImage: "info.circle").font(.headline)
                switch model.inspections[video.id] {
                case .some(.checking):
                    HStack { ProgressView().controlSize(.small); Text("Checking for a local original…").font(.caption) }
                case .some(.downloading(let fraction)):
                    let progress = fraction.isFinite ? min(1, max(0, fraction)) : 0
                    ProgressView(value: progress)
                    Text("Downloading original for inspection… \(Int(progress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                case .some(.needsDownload):
                    Text("The original is not available locally. Inspect it to see the actual frame rate and HDR before choosing compression settings.")
                        .font(.caption).foregroundStyle(.secondary)
                case .some(.failed(let message)):
                    Text(message).font(.caption).foregroundStyle(.orange)
                default:
                    Text("Inspect the original to check its frame rate and HDR. Local originals are read without downloading them again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.inspections[video.id]?.isWorking == true {
                    Button("Cancel inspection") { model.cancelInspection(id: video.id) }
                } else {
                    Button("Inspect original…") { model.requestInspection(video) }.disabled(model.isBusy)
                    Text("If an iCloud download is needed, you will be asked first. Playback may use a streamed preview instead of the original.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        } else if video.hasInspectedFacts, video.facts.frameRate > 60 {
            Label("High-frame-rate original · \(video.facts.frameRate.formatted(.number.precision(.fractionLength(0...2)))) fps", systemImage: "film")
                .font(.caption.weight(.medium))
            Text("Original frame rate keeps this rate. Choosing a lower cap explicitly removes frames; high-frame-rate footage can be useful for slow-motion editing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
