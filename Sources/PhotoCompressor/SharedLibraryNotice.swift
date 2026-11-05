import SwiftUI

struct SharedLibraryNotice: View {
    @EnvironmentObject private var model: AppModel
    var replacementID: String? = nil
    var compact = false
    var restoredOriginal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Shared Library placement is not verified", systemImage: "person.2.badge.gearshape")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                Spacer()
                if let replacementID {
                    Button(restoredOriginal ? "Show original in Photos" : "Show copy in Photos") { model.showInPhotos(id: replacementID) }
                        .controlSize(.small).disabled(!model.connected || model.isBusy)
                }
            }
            Text(restoredOriginal ? "A restored original is a new Photos item. If it was shared, check and move it back to Shared Library in Photos." : "If the original was in iCloud Shared Photo Library, move the compressed copy back there in Photos before deleting the original.")
                .font(.caption).foregroundStyle(.secondary)
            if !compact {
                Text("Shared Library membership cannot be read or restored with the public APIs used here. Regular album checks do not include it. In Photos, select the copy and choose Image → Move to Shared Library.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Apple’s Shared Library instructions", destination: URL(string: "https://support.apple.com/guide/photos/pht9a3599aac/mac")!).font(.caption)
            }
        }.padding(10).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
