import AppKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppState.self) private var appState
    /// Keep Settings mounted after first visit so tab switches don't rebuild the Form.
    @State private var settingsMounted = false

    var body: some View {
        @Bindable var appState = appState
        let showRecordings = appState.tab == .recordings
        let showSettings = appState.tab == .settings

        NavigationStack {
            ZStack {
                RecordingsView()
                    .opacity(showRecordings ? 1 : 0)
                    .allowsHitTesting(showRecordings)
                    .accessibilityHidden(!showRecordings)

                if settingsMounted {
                    SettingsView()
                        .opacity(showSettings ? 1 : 0)
                        .allowsHitTesting(showSettings)
                        .accessibilityHidden(!showSettings)
                }
            }
            // Segmented Picker selection animates; don't let that animation drive a content remount/layout morph.
            .animation(nil, value: appState.tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.clear)
            .navigationTitle("Oat")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("View", selection: $appState.tab) {
                        Text("Recordings").tag(AppState.Tab.recordings)
                        Text("Settings").tag(AppState.Tab.settings)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(minWidth: 196)
                }
            }
            .onChange(of: appState.tab) { _, tab in
                if tab == .settings {
                    settingsMounted = true
                    appState.prepareSettings()
                }
            }
        }
        .oatWindowGlass()
        .background(HideOnCloseWindow())
        .onAppear {
            if appState.tab == .settings {
                settingsMounted = true
            }
            appState.activate()
        }
    }
}

/// Keeps the app alive in the menu bar: close hides the window instead of destroying it.
private struct HideOnCloseWindow: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        func attach(to view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                window.isReleasedWhenClosed = false
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titlebarSeparatorStyle = .none
                window.isMovableByWindowBackground = true
                window.delegate = self
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }
    }
}
