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
    private var title: String {
        if placed { return "Both items detected in Shared Library" }
        if source?.state == .shared { return "Original was shared · check the \(restoredOriginal ? "restored original" : "copy")" }
        if personal { return "Both items detected in Personal Library" }
        return "Shared Library placement is Unknown"
    }
    private var explanation: String {
        if placed { return "Database metadata indicates the copy is shared. Check its placement and synchronization in Photos before deleting the original." }
        if personal { return "Database metadata indicates both items are personal. This is an advisory result and does not verify iCloud synchronization." }
        if source?.state == .shared {
            return "\(restoredOriginal ? "The restored original" : "The compressed copy") is \(target?.state == .personal ? "detected in Personal Library" : "not confirmed as shared"). In Photos, select it and choose Image → Move to Shared Library before deleting the shared source."
        }
        return restoredOriginal ? "A restored original is a new Photos item. If the original was shared, check and move it back to Shared Library in Photos." : "If the original was in iCloud Shared Photo Library, move the compressed copy there in Photos before deleting the original."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(record == nil ? "Shared Library needs a separate check" : title, systemImage: "person.2.badge.gearshape")
                    .font(.caption.weight(.semibold)).foregroundStyle(placed || personal ? Color.secondary : Color.orange)
                Spacer()
                if let replacementID {
                    Button(restoredOriginal ? "Show original in Photos" : "Show copy in Photos") { model.showInPhotos(id: replacementID) }
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
                if let record, let saved = record.sourceSharedLibrary, model.sharing.observation(for: record.sourceID).state == .unknown {
                    Text("Original result saved at compression: \(saved.checkedAt.formatted()). It may have changed since then.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(record == nil ? "Detected shared originals are kept for Review, even with automatic replacement. Sharing cannot be restored automatically; Unknown items still need a manual check." : explanation)
                .font(.caption).foregroundStyle(.secondary)
            if !compact {
                Text("Optional read-only database detection is advisory. Choose your current System Photo Library in the Library settings; backups or stale metadata can give outdated results. Moving an item to Shared Library must be done in Photos.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Apple’s Shared Library instructions", destination: URL(string: "https://support.apple.com/guide/photos/pht9a3599aac/mac")!).font(.caption)
            }
        }.padding(10).background((placed || personal ? Color.secondary : Color.orange).opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
