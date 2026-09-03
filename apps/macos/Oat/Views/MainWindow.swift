import AppKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationStack {
            Group {
                if appState.tab == .recordings {
                    RecordingsView()
                } else {
                    SettingsView()
                }
            }
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
                    .onChange(of: appState.tab) { _, tab in
                        if tab == .settings {
                            appState.prepareSettings()
                        }
                    }
                }
            }
        }
        .oatWindowGlass()
        .background(HideOnCloseWindow())
        .onAppear {
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
