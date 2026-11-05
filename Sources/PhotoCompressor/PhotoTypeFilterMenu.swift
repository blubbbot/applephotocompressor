import SwiftUI
import CompressionCore

struct PhotoTypeFilterMenu: View {
    @Binding var selection: PhotoTypeFilter
    var body: some View {
        Menu {
            Button("Show all photo types") { selection = .all }
            Button("Normal photos only") { selection = .normal }
            Divider()
            ForEach(PhotoType.allCases) { type in
                Toggle(type.title, isOn: Binding(get: { selection.types.contains(type) }, set: { shown in
                    if shown { selection.types.insert(type) } else { selection.types.remove(type) }
                }))
            }
        } label: {
            Label(selection.title, systemImage: "line.3.horizontal.decrease.circle")
        }.menuStyle(.borderlessButton).controlSize(.small)
            .help("Choose shown photo types. Normal photos excludes Live Photos and panoramas. Selected types are combined.")
            .accessibilityLabel("Photo types: \(selection.title)")
    }
}
