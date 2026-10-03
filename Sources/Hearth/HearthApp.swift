import SwiftUI
import AppKit
import Combine
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidBecomeActive(_ notification: Notification) { store?.refresh() }
    func applicationWillTerminate(_ notification: Notification) { store?.shutdown() }
}

/// Sparkle asks on the second launch before checking automatically; until then, and if the
/// user declines, it only checks from this menu item.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?
    var isAvailable: Bool { controller != nil }
    init() {
        // Development runs and tests have no update feed.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }
    func check() { controller?.checkForUpdates(nil) }
}

@main
struct HearthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()
    @StateObject private var updates = UpdateChecker()
    var body: some Scene {
        WindowGroup {
            ContentView().environment(store)
                .frame(minWidth: 1020, minHeight: 710)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1220, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                if updates.isAvailable {
                    Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { store.newChat() }.keyboardShortcut("n")
            }
            CommandMenu("Assistant") {
                Button("Explore Models") { store.openCatalog() }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Stop Response") { store.stopOperation() }.keyboardShortcut(".").disabled(!store.busy)
                Button("Release Model Memory") { store.unload() }.disabled(store.busy || store.activeID == nil)
                Button("Export Conversation…") { store.exportConversation() }.disabled(store.conversation == nil)
            }
        }
    }
}
