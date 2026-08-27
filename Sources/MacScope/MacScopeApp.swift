import MacScopeCore
import SwiftUI

@main
struct MacScopeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("MacScope", id: "main") {
            AppShell(model: model)
                .frame(minWidth: 1_050, minHeight: 700)
                .tint(MacScopeTheme.accent)
                .task { model.startAutomaticallyIfNeeded() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            CommandMenu("Monitor") {
                Button(model.isRunning ? "Pause Sampling" : "Resume Sampling") {
                    model.isRunning ? model.stop() : model.start()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarStatusLabel(presentation: model.menuBarPresentation)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

struct AppShell: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(model.availableSections, selection: $model.selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationTitle("MacScope")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
            .safeAreaInset(edge: .bottom) {
                SamplingStatus(model: model)
                    .padding(10)
                    .background(.bar)
            }
        } detail: {
            SectionContent(section: model.selectedSection ?? .overview, model: model)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct SamplingStatus: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRunning ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.isRunning ? "Live" : "Paused").font(.caption.weight(.medium))
                Text(model.snapshot.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
