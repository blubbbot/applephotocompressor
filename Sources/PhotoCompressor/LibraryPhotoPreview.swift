import SwiftUI
import PhotosUI
import CompressionCore

@MainActor
final class LibraryPhotoPreviewModel: ObservableObject {
    @Published var image: NSImage?
    @Published var livePhoto: PHLivePhoto?
    @Published var loading = false
    @Published var progress: Double?
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var revision = UUID()

    func load(_ photo: LibraryVideo) async {
        cancel()
        let token = UUID(); revision = token
        image = nil; livePhoto = nil; error = nil; progress = nil; loading = true
        let worker = Task {
            defer { if revision == token { loading = false } }
            do {
                guard let asset = photo.asset else { throw MediaError.invalid("The Photos preview is unavailable.") }
                if photo.kind == .livePhoto {
                    let loaded = try await PhotosService.livePhotoPreview(asset) { value in
                        Task { @MainActor [weak self] in
                            guard let self, self.revision == token, self.loading else { return }
                            self.progress = min(1, max(0, value))
                        }
                    }
                    guard !Task.isCancelled, revision == token else { return }
                    livePhoto = loaded
                } else {
                    let loaded = try await PhotosService.photoPreview(asset)
                    guard !Task.isCancelled, revision == token else { return }
                    image = loaded
                }
            } catch {
                guard !Task.isCancelled, revision == token else { return }
                self.error = error.localizedDescription
                // A missing/unavailable motion resource should not take away a
                // still preview that Photos can otherwise display.
                if photo.kind == .livePhoto, let asset = photo.asset,
                   let still = try? await PhotosService.photoPreview(asset), !Task.isCancelled, revision == token {
                    image = still
                }
            }
        }
        task = worker
        await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }

    func cancel() {
        revision = UUID(); task?.cancel(); task = nil; loading = false; progress = nil
    }
}

struct LibraryPhotoPreview: View {
    let photo: LibraryVideo
    @StateObject private var preview = LibraryPhotoPreviewModel()
    @State private var retry = 0
    @State private var playRequest = 0
    @State private var stopRequest = 0
    @State private var playing = false
    @State private var muted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color.black
                if let livePhoto = preview.livePhoto {
                    NativeLivePhoto(livePhoto: livePhoto, playRequest: playRequest, muted: muted, stopRequest: stopRequest) { playing = $0 }
                } else if let image = preview.image { Image(nsImage: image).resizable().scaledToFit() }
                else if preview.loading { ProgressView().tint(.white) }
                else { Text(preview.error ?? "Preview stopped. Retry to load it.").font(.caption).foregroundStyle(.white).multilineTextAlignment(.center).padding(20) }
            }.frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                if photo.kind == .livePhoto {
                    Button {
                        if playing { stopRequest += 1; playing = false }
                        else { playRequest += 1; playing = true }
                    } label: { Label(playing ? "Stop motion" : "Play motion", systemImage: playing ? "stop.fill" : "play.fill") }
                        .disabled(preview.livePhoto == nil)
                    Toggle("Mute", isOn: $muted).toggleStyle(.checkbox).disabled(preview.livePhoto == nil)
                }
                if preview.loading {
                    Text(preview.progress.map { "Downloading preview · \(Int($0 * 100))%" } ?? "Loading preview…")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { preview.cancel() }
                } else if preview.livePhoto == nil && (photo.kind == .livePhoto || preview.image == nil) {
                    Button("Retry preview") { retry += 1 }
                }
            }.controlSize(.small)
            if photo.kind == .livePhoto {
                if let error = preview.error, preview.image != nil {
                    Label("Motion unavailable: \(error)", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Motion and sound play on demand. Loading the preview may download it from iCloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(photo.id)-\(photo.asset?.modificationDate?.timeIntervalSinceReferenceDate ?? 0)-\(retry)") { playing = false; playRequest = 0; stopRequest = 0; await preview.load(photo) }
        .onDisappear { preview.cancel(); playing = false }
    }
}
