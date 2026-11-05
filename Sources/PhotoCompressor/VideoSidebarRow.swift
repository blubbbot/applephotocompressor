import SwiftUI
import AVKit
import CompressionCore

// Both workspaces use the native List selection and row spacing. Keep the row
// content compact so a filename never wraps into a tall, narrow card.
struct VideoSidebarRow<Thumbnail: View>: View {
    let title: String
    let detail: String
    let status: String
    var savings: String? = nil
    var statusColor: Color = .secondary
    var progress: Double? = nil
    var sharing: SharedLibraryObservation? = nil
    var sharingPrefix = ""
    @ViewBuilder let thumbnail: () -> Thumbnail

    var body: some View {
        HStack(spacing: 10) {
            thumbnail()
                .frame(width: 48, height: 40)
                .clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).help(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let sharing { SharedLibraryBadge(observation: sharing, prefix: sharingPrefix) }
                if let savings {
                    Text(savings).font(.callout.weight(.semibold)).foregroundStyle(.green)
                        .lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                }
                if !status.isEmpty {
                    Text(status).font(.caption2).foregroundStyle(statusColor)
                        .lineLimit(1).truncationMode(.tail).help(status)
                }
                if let progress { ProgressView(value: progress).controlSize(.mini) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct ReviewThumbnail: View {
    let url: URL
    var isPhoto = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "film").foregroundStyle(.secondary) }
        }
        .task(id: url) {
            image = nil
            if isPhoto {
                image = await Task.detached { PhotoPreviewRenderer.render(url, maximum: 144) }.value
                return
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 144, height: 120)
            if let result = try? await generator.image(at: .zero), !Task.isCancelled {
                image = NSImage(cgImage: result.image, size: .zero)
            }
        }
    }
}
