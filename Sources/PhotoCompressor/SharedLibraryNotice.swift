import SwiftUI
import CompressionCore

struct SharedLibraryBadge: View {
    let observation: SharedLibraryObservation
    var prefix = ""
    var body: some View {
        Label(prefix + observation.state.title, systemImage: observation.state == .shared ? "person.2.fill" : observation.state == .personal ? "person.fill" : "questionmark.circle")
            .font(.caption2).foregroundStyle(observation.state == .shared ? Color.orange : Color.secondary)
            .lineLimit(1).help("\(prefix)\(observation.state.title) (database, advisory) · \(observation.checkedAt.formatted())\n\(observation.detail)")
    }
}

struct SharedLibraryDetectionSettings: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Detect Shared Library (read-only)", isOn: Binding(get: { model.sharing.enabled }, set: { value in
                if value && model.sharing.library == nil { model.chooseSharingLibrary() }
                else { model.sharing.setEnabled(value); if value { model.refreshSharing(force: true) } }
            })).disabled(model.isBusy)
            Text("Choose the same System Photo Library connected above. Shared / Personal labels use undocumented database metadata; an unreadable or unmatched item stays Unknown.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.sharing.library == nil ? "Choose library…" : "Change library…") { model.chooseSharingLibrary() }
                Button("Refresh") { model.refreshSharing(force: true) }
                    .disabled(!model.connected || !model.sharing.enabled || model.sharing.library == nil || model.sharing.checking)
                if model.sharing.checking { ProgressView().controlSize(.small) }
            }.controlSize(.small).disabled(model.isBusy)
            Text(model.sharing.status).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// Expanded review keeps the sharing action in the existing toolbar row.
/// Long instructions are in the menu instead of covering the previews.
struct SharedLibraryToolbarHint: View {
    @EnvironmentObject private var model: AppModel
    let record: OperationRecord
    private var original: SharedLibraryState { model.sourceSharing(record)?.state ?? .unknown }
    private var target: SharedLibraryState { record.reviewPhotosID.map { model.sharing.observation(for: $0).state } ?? .unknown }
    private var needsSharing: Bool { original == .shared && target != .shared }
    private var restored: Bool { record.stage == .reverted }
    var body: some View {
        Menu {
            Text("Original: \(original.title) · \(restored ? "Restored" : "Copy"): \(target.title) (advisory)")
            if needsSharing { Text("In Photos: Image → Move to Shared Library. Then refresh here.") }
            if let id = record.reviewPhotosID {
                Button(restored ? "Show original in Photos" : needsSharing ? "Show copy to re-share…" : "Show copy in Photos") { model.showInPhotos(id: id) }
                    .disabled(!model.connected || model.isBusy)
            }
            Button("Refresh sharing metadata") { model.refreshSharing(force: true) }
                .disabled(!model.connected || !model.sharing.enabled || model.sharing.checking || model.isBusy)
            Link("Shared Library instructions", destination: URL(string: "https://support.apple.com/guide/photos/pht9a3599aac/mac")!)
        } label: {
            Label(needsSharing ? "Re-share" : target == .shared ? "Shared" : "Sharing", systemImage: needsSharing ? "person.2.badge.gearshape" : "person.2")
                .foregroundStyle(needsSharing ? Color.orange : Color.secondary)
        }.menuStyle(.borderlessButton).fixedSize()
            .help("Original: \(original.title); current Photos item: \(target.title). \(needsSharing ? "Open the copy in Photos and choose Image → Move to Shared Library." : "Database placement is advisory.")")
    }
}

struct SharedLibraryNotice: View {
    @EnvironmentObject private var model: AppModel
    var replacementID: String? = nil
    var compact = false
    var restoredOriginal = false
    var record: OperationRecord? = nil

    private var source: SharedLibraryObservation? { record.flatMap(model.sourceSharing) }
    private var target: SharedLibraryObservation? { replacementID.map { model.sharing.observation(for: $0) } }
    private var placed: Bool { source?.state == .shared && target?.state == .shared }
    private var personal: Bool { source?.state == .personal && target?.state == .personal }
    private var originalRemoved: Bool { record?.stage == .originalDeleted }
    private var needsSharing: Bool { source?.state == .shared && target?.state != .shared }
    private var title: String {
        if placed { return "\(restoredOriginal ? "Restored original" : "Replacement") detected in Shared Library" }
        if needsSharing && originalRemoved { return "Shared original replaced · re-share the copy" }
        if source?.state == .shared { return "Original was shared · check the \(restoredOriginal ? "restored original" : "copy")" }
        if personal { return "\(restoredOriginal ? "Restored original" : "Replacement") detected in Personal Library" }
        return "Shared Library placement is Unknown"
    }
    private var explanation: String {
        if placed { return "Database metadata indicates this Photos item is shared. \(originalRemoved ? "The full original remains in your local archive." : "Check its placement and synchronization in Photos before deleting the original.")" }
        if personal { return "The original was recorded as personal; database metadata indicates this Photos item is also personal. This is advisory and does not verify iCloud synchronization." }
        if source?.state == .shared {
            let placement = "\(restoredOriginal ? "The restored original" : "The compressed copy") is \(target?.state == .personal ? "detected in Personal Library" : "not confirmed as shared")."
            let action = "Open it with the button above, then choose Image → Move to Shared Library in Photos. Return here and Refresh to check placement."
            return "\(placement) \(action) \(originalRemoved ? "The original has already been replaced; its full local archive is retained." : restoredOriginal ? "The original pair remains archived locally." : "You can move the copy before accepting original deletion, or re-share it after automatic replacement.")"
        }
        return restoredOriginal ? "A restored original is a new Photos item. If the original was shared, check and move it back to Shared Library in Photos." : "If the original was in iCloud Shared Photo Library, open the compressed copy in Photos and choose Image → Move to Shared Library. \(originalRemoved ? "The original has already been replaced; its full local archive is retained." : "Automatic replacement can delete the original before you re-share its copy.")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(record == nil ? "Shared Library needs a separate check" : title, systemImage: "person.2.badge.gearshape")
                    .font(.caption.weight(.semibold)).foregroundStyle(placed || personal ? Color.secondary : Color.orange)
                Spacer()
                if let replacementID {
                    Button(needsSharing ? (restoredOriginal ? "Show original to re-share…" : "Show copy to re-share…") : (restoredOriginal ? "Show original in Photos" : "Show copy in Photos")) { model.showInPhotos(id: replacementID) }
                        .buttonStyle(.bordered).help("Open this item in Photos. Choose Image → Move to Shared Library there.")
                        .controlSize(.small).disabled(!model.connected || model.isBusy)
                }
            }
            if record != nil {
                HStack(spacing: 16) {
                    if let source { SharedLibraryBadge(observation: source, prefix: "Original: ") }
                    if let target { SharedLibraryBadge(observation: target, prefix: restoredOriginal ? "Restored: " : "Copy: ") }
                    Button("Refresh") { model.refreshSharing(force: true) }.controlSize(.mini)
                        .disabled(!model.connected || !model.sharing.enabled || model.sharing.checking || model.isBusy)
                }
                if let record, let saved = record.sourceSharedLibrary {
                    Text("Original result saved at compression: \(saved.checkedAt.formatted()). It may have changed since then.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(record == nil ? "Replace originals also applies to shared items. Their copies may start in Personal Library. In Review, filter Shared originals or Needs re-sharing, open each replacement in Photos, and move it to Shared Library." : explanation)
                .font(.caption).foregroundStyle(.secondary)
            if !compact {
                Text("Optional read-only database detection is advisory. Choose your current System Photo Library in the Library settings; backups or stale metadata can give outdated results. Moving an item to Shared Library must be done in Photos.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Apple’s Shared Library instructions", destination: URL(string: "https://support.apple.com/guide/photos/pht9a3599aac/mac")!).font(.caption)
            }
        }.padding(10).background((placed || personal ? Color.secondary : Color.orange).opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
