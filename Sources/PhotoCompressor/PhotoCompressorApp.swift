import SwiftUI
import CoreServices
import Combine

@main
struct PhotoCompressorApp: App {
    @NSApplicationDelegateAdaptor(PhotoCompressorDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Photo Compressor") {
            ContentView().environmentObject(model)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear {
                    appDelegate.model = model
                    NSApplication.shared.setActivationPolicy(.regular)
                    AppIcon.applyToDock()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    exportDemoSnapshotIfRequested()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Connect Photos Library…") { model.connect() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.isBusy)
                Button(model.mediaMode == .photos ? "Open Photo Files…" : "Open Video Files…") { model.openFiles() }.keyboardShortcut("o").disabled(model.isBusy)
                Divider()
                Button("Choose Library for Sharing Detection…") { model.chooseSharingLibrary() }.disabled(model.isBusy)
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

enum AppIcon {
    static let image: NSImage? = {
        let filename = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "PhotoCompressorIcon.icns"
        let name = (filename as NSString).deletingPathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }()

    static func applyToDock() {
        guard let image else { return }
        NSApplication.shared.applicationIconImage = image
        NSApplication.shared.dockTile.display()
    }
}

@MainActor
final class PhotoCompressorDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationObserver: AnyCancellable?
    private var waitingToQuit = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if waitingToQuit { return .terminateLater }
        guard let model, model.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Work is still in progress"
        alert.informativeText = "Photo Compressor will finish the current safe checkpoint before quitting. Interrupted and queued items can be resumed from History next time. Photos changes already awaiting confirmation must finish first."
        alert.addButton(withTitle: model.isReviewing ? "Wait and quit" : "Stop safely and quit")
        alert.addButton(withTitle: "Keep working")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        // Work may have finished while the alert's modal loop was running.
        guard model.isBusy else { return .terminateNow }
        waitingToQuit = true
        terminationObserver = model.$isBusy.filter { !$0 }.first().receive(on: RunLoop.main).sink { [weak self, weak sender] _ in
            self?.waitingToQuit = false
            self?.terminationObserver = nil
            sender?.reply(toApplicationShouldTerminate: true)
        }
        if !model.isReviewing { model.stop() }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refresh this app's own registration after an update or move, so file
        // browsers and Dock folder stacks can resolve the bundled icon too.
        if Bundle.main.bundleURL.pathExtension == "app" {
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        }
        AppIcon.applyToDock()
    }
}
