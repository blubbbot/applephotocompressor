import SwiftUI

@main
struct PhotoCompressorApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Photo Compressor") {
            ContentView().environmentObject(model)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    exportDemoSnapshotIfRequested()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Connect Photos Library…") { model.connect() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.isBusy)
                Button("Open Video Files…") { model.openFiles() }.keyboardShortcut("o").disabled(model.isBusy)
            }
        }
    }

    private func exportDemoSnapshotIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--demo"), let index = arguments.firstIndex(of: "--snapshot-demo"), arguments.indices.contains(index + 1) else { return }
        let destination = URL(fileURLWithPath: arguments[index + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let view = NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                  let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: image)
            if let data = image.representation(using: .png, properties: [:]) { try? data.write(to: destination) }
        }
    }
}
