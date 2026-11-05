import SwiftUI
import PhotosUI
import ImageIO
import CompressionCore

enum PhotoPreviewRenderer {
    static func render(_ url: URL, maximum: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximum] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

struct PhotoFilePreview: View {
    let url: URL
    var motion: URL? = nil
    var playRequest = 0
    var muted = false
    @State private var image: NSImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var error: String?
    @State private var revision = 0
    var body: some View {
        ZStack {
            Color.black
            if let livePhoto { NativeLivePhoto(livePhoto: livePhoto, playRequest: playRequest, muted: muted) }
            else if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if let error {
                VStack(spacing: 10) {
                    Text(error).font(.caption).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Retry photo preview") { revision += 1 }.buttonStyle(.bordered)
                }.padding()
            }
            else { ProgressView().tint(.white) }
        }
        .task(id: "\(url.path)-\(revision)") {
            image = nil; livePhoto = nil; error = nil
            do {
                if let motion {
                    let loaded = try await PhotosService.livePhoto(photo: url, motion: motion)
                    try Task.checkCancellation(); livePhoto = loaded
                }
                else {
                    let rendered = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary) else { return nil }
                        return NSImage(cgImage: cgImage, size: .zero)
                    }.value
                    try Task.checkCancellation()
                    guard let rendered else { throw MediaError.invalid("Photo archive unavailable. Connect its archive disk and retry.") }
                    image = rendered
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct NativeLivePhoto: NSViewRepresentable {
    let livePhoto: PHLivePhoto
    let playRequest: Int
    let muted: Bool
    final class Coordinator { var played = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView(); view.contentMode = .aspectFit
        view.livePhoto = livePhoto; view.isMuted = muted
        return view
    }
    func updateNSView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
        view.isMuted = muted
        if context.coordinator.played != playRequest {
            context.coordinator.played = playRequest; view.startPlayback(with: .full)
        }
    }
    static func dismantleNSView(_ view: PHLivePhotoView, coordinator: Coordinator) { view.stopPlayback() }
}

struct PhotoComparison: View {
    let record: OperationRecord
    let height: CGFloat
    @State private var playRequest = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                pane(title: record.kind == .livePhoto ? "Original Live Photo" : "Original", path: record.backupPath,
                     facts: record.photoFacts, bytes: record.originalBytes,
                     motion: record.kind == .livePhoto ? record.pairedVideoPath : nil, muted: false)
                pane(title: record.outputIsLivePhoto ? "Compressed Live Photo" : "Compressed still photo", path: record.outputPath,
                     facts: record.outputPhotoFacts, bytes: record.outputBytes,
                     motion: record.outputIsLivePhoto ? record.pairedVideoPath : nil, muted: true)
            }
            if record.kind == .livePhoto {
                Button(record.outputIsLivePhoto ? "Play both Live Photos (original audio)" : "Play original Live Photo") { playRequest += 1 }
                Text(record.outputIsLivePhoto ? "The original motion file, timing, and sound are retained byte for byte. Only the still image is re-encoded." : "Converted to a still photo as requested. The compressed Photos copy has no motion or sound; the full original pair remains archived.")
                    .font(.caption).foregroundStyle(record.outputIsLivePhoto ? Color.secondary : .orange)
            }
        }
    }
    private func pane(title: String, path: String, facts: PhotoFacts?, bytes: Int64?, motion: String?, muted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.headline); Spacer(); Text(bytes.map(DisplayFormat.bytes) ?? "Size pending").font(.caption).foregroundStyle(.secondary) }
            PhotoFilePreview(url: URL(fileURLWithPath: path), motion: motion.map { URL(fileURLWithPath: $0) }, playRequest: playRequest, muted: muted)
                .frame(height: height).clipShape(RoundedRectangle(cornerRadius: 12))
            if let facts { Text("\(facts.width) × \(facts.height) · \(motion == nil ? "still image" : "image + motion")").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity)
    }
}

struct PhotoDetailView: View {
    @EnvironmentObject private var model: AppModel
    let photo: LibraryVideo
    @State private var image: NSImage?
    @State private var error: String?
    @State private var previewRequest = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(photo.kind == .livePhoto ? "Live Photo preview" : "Photo preview").font(.headline)
                    Spacer()
                    if let id = photo.asset?.localIdentifier { Button("Show in Photos") { model.showInPhotos(id: id) } }
                }
                ZStack {
                    Color.black
                    if let url = photo.fileURL { PhotoFilePreview(url: url) }
                    else if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else if let error {
                        VStack(spacing: 10) {
                            Text(error).foregroundStyle(.white).font(.caption)
                            Button("Retry preview") { previewRequest += 1 }
                        }.padding()
                    }
                    else { ProgressView().tint(.white) }
                }.frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 12))
                Text(photo.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text("\(photo.facts.width) × \(photo.facts.height) · \(photo.facts.bytes.map(DisplayFormat.bytes) ?? "Size pending")")
                    .font(.callout).foregroundStyle(.secondary)
                if let reason = photo.unsupportedReason { Label(reason, systemImage: "lock.fill").foregroundStyle(.orange) }
                else {
                    Text("Lossy HEIC compression · \(model.photoSettings.resolution.rawValue) resolution · quality \(Int(model.photoSettings.quality * 100))%")
                        .font(.headline)
                    Text("Fine detail, texture, and gradients can change. JPEG → HEIC often offers more savings than re-encoding an existing HEIC. The size estimate is rough; only measured savings qualify a finished copy for import.")
                        .font(.callout).foregroundStyle(.secondary)
                    if photo.kind == .livePhoto {
                        Label(model.photoSettings.convertLiveToStill ? "Convert to still: motion and sound will be removed from the copy." : "Keep Live Photo: original motion and sound are retained; only the still image is compressed.", systemImage: "livephoto")
                            .foregroundStyle(model.photoSettings.convertLiveToStill ? Color.orange : .secondary)
                        Text("The motion file's size is measured when the original pair is archived. The initial size-saving estimate is provisional.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let output = model.outputRecord(for: photo.id), output.hasReviewableCopy {
                        Button("Review original and compressed photo") { model.openReview(output) }
                    }
                    Button(model.selected.contains(photo.id) ? "Selected for compression" : "Select for compression") { model.toggle(photo) }
                        .disabled(model.isBusy)
                }
                if let status = model.statuses[photo.id] { Text(status.text).foregroundStyle(status.failed ? Color.orange : .secondary) }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(photo.id)-\(previewRequest)") {
            image = nil; error = nil
            if let asset = photo.asset {
                do { let preview = try await PhotosService.photoPreview(asset); if !Task.isCancelled { image = preview } }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        }
    }
}

struct PhotoSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Photo compression").font(.title3.weight(.semibold))
            Text("HEIC still images · ordinary JPEG/HEIC and supported Live Photos").font(.caption).foregroundStyle(.secondary)
            Picker("Maximum long edge", selection: $model.photoSettings.resolution) { ForEach(PhotoResolution.allCases) { Text($0.rawValue).tag($0) } }
            HStack { Text("Picture quality"); Spacer(); Text("\(Int(model.photoSettings.quality * 100))%").monospacedDigit() }.font(.callout)
            Slider(value: $model.photoSettings.quality, in: 0.4...1, step: 0.05)
            Text("Even at 100%, HEIC re-encoding is lossy. Existing HEIC photos may save little. HDR, RAW, depth/Portrait, spatial, burst, and edited resources are protected.").font(.caption).foregroundStyle(.secondary)
            Toggle("Convert Live Photos to stills", isOn: $model.photoSettings.convertLiveToStill)
            Text(model.photoSettings.convertLiveToStill ? "Removes motion and sound from Live Photo copies. Full original pairs are archived for recovery." : "Default: preserve Live Photo motion and sound without re-encoding. This limits savings, especially for photos already in HEIC.")
                .font(.caption).foregroundStyle(model.photoSettings.convertLiveToStill ? Color.orange : .secondary)
            HStack { Text("Minimum measured savings"); Spacer(); Text("\(Int(model.photoSettings.minimumSavings * 100))%") }.font(.caption)
            Slider(value: $model.photoSettings.minimumSavings, in: 0.05...0.7, step: 0.05)
            Text("Both image and motion bytes count. Copies below this threshold are not imported.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
