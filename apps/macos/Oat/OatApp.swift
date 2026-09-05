import AppKit
import SwiftUI

@main
struct OatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("Oat", id: AppWindow.mainId) {
            MainWindow()
                .environment(appState)
                .frame(minWidth: 360, minHeight: 520)
        }
        .defaultSize(width: 380, height: 560)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appState.tab = .settings
                    AppWindow.show()
                    Task { await appState.checkForUpdates(userInitiated: true) }
                }
            }
            CommandMenu("Recording") {
                Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
                    Task { await appState.toggleRecording() }
                }
                .disabled(!appState.canRecord && !appState.isRecording)
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        MenuBarExtra {
            TrayMenu()
                .environment(appState)
        } label: {
            TrayIcon(isRecording: appState.isRecording)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppWindow.show()
        }
        return true
    }
}

enum AppWindow {
    static let mainId = "main"

    @MainActor
    @discardableResult
    static func show() -> NSWindow? {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: \.isOatMainWindow) else { return nil }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return window
    }

    @MainActor
    static func hide(_ window: NSWindow) {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
}

private extension NSWindow {
    var isOatMainWindow: Bool {
        styleMask.contains(.titled) && level == .normal
    }
}

private struct TrayMenu: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
            Task { await appState.toggleRecording() }
        }
        .keyboardShortcut("r")
        .disabled(!appState.canRecord && !appState.isRecording)

        Divider()

        Button("Open Oat") {
            showMain()
        }
        Button("Settings…") {
            appState.tab = .settings
            showMain()
        }
        if let update = appState.availableUpdate, appState.canInstallUpdate {
            Button("Update to \(update.version)…") {
                appState.tab = .settings
                showMain()
                Task { await appState.installAvailableUpdate() }
            }
            .disabled(appState.isRecording)
        }

        Divider()

        Button("Quit Oat") {
            appState.quit()
        }
        .keyboardShortcut("q")
    }

    private func showMain() {
        openWindow(id: AppWindow.mainId)
        DispatchQueue.main.async {
            AppWindow.show()
        }
    }
}

private struct TrayIcon: View {
    var isRecording: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: TrayGlyph.image(recording: isRecording, dark: colorScheme == .dark))
            .renderingMode(.original)
            .interpolation(.high)
            .accessibilityLabel(isRecording ? "Oat is recording" : "Oat")
    }
}
