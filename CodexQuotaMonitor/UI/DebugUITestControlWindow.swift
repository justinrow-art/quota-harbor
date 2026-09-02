#if DEBUG
import AppKit
import SwiftUI

@MainActor
struct DebugUITestControlActions {
    let showPanel: () -> Void
    let hidePanel: () -> Void
    let reopen: () -> Void
    let showSettings: () -> Void
    let quit: () -> Void
}

@MainActor
final class DebugUITestControlWindowController {
    private let window: NSWindow

    init(
        launch: DebugUITestLaunch,
        probe: DebugUITestProbe,
        actions: DebugUITestControlActions
    ) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "UI 測試控制台"
        window.identifier = NSUserInterfaceItemIdentifier(
            "debug.control.window"
        )
        window.setAccessibilityIdentifier("debug.control.window")
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(
            rootView: DebugUITestControlView(
                launch: launch,
                probe: probe,
                actions: actions
            )
        )
    }

    func show() {
        window.orderFrontRegardless()
    }
}

private struct DebugUITestControlView: View {
    let launch: DebugUITestLaunch
    @Bindable var probe: DebugUITestProbe
    let actions: DebugUITestControlActions

    @State private var selectedThemeID =
        DebugThemeStatePreviewMatrix.themeIDs[0]
    @State private var selectedPreviewState = DebugThemePreviewState.fresh

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("安全假執行環境")
                    .font(.headline)
                    .accessibilityIdentifier("debug.control.safety")
                LabeledContent("Fixture", value: launch.preset.rawValue)
                    .accessibilityIdentifier("debug.control.preset")
                LabeledContent("Session", value: launch.sessionID.uuidString)
                    .accessibilityIdentifier("debug.control.session")
                Divider()
                probeCounters
                ownerCounters
                if launch.preset == .themeStatePreviews {
                    themePreviewSelector
                }
                Divider()
                HStack {
                    Button("顯示卡片", action: actions.showPanel)
                        .accessibilityIdentifier("debug.control.show-panel")
                    Button("隱藏卡片", action: actions.hidePanel)
                        .accessibilityIdentifier("debug.control.hide-panel")
                    Button("重新開啟", action: actions.reopen)
                        .accessibilityIdentifier("debug.control.reopen")
                }
                HStack {
                    Button("顯示設定", action: actions.showSettings)
                        .accessibilityIdentifier("debug.control.show-settings")
                    Spacer()
                    Button("結束測試 App", action: actions.quit)
                        .accessibilityIdentifier("debug.control.quit")
                }
            }
            .padding(20)
        }
        .frame(width: 500, height: 600, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("debug.control.root")
    }

    private var probeCounters: some View {
        GroupBox("實際呼叫計數") {
            VStack(alignment: .leading, spacing: 4) {
                counter(
                    "login.register",
                    probe.loginRegisterCount,
                    id: "debug.probe.login-register"
                )
                counter(
                    "login.unregister",
                    probe.loginUnregisterCount,
                    id: "debug.probe.login-unregister"
                )
                counter(
                    "fake.refresh",
                    probe.fakeRefreshCount,
                    id: "debug.probe.fake-refresh"
                )
                counter(
                    "fake.system-opener-request",
                    probe.fakeSystemSettingsOpenerRequestCount,
                    id: "debug.probe.fake-system-opener"
                )
                counter(
                    "production.system-opener",
                    probe.productionSystemSettingsOpenerCount,
                    id: "debug.probe.production-system-opener"
                )
                counter(
                    "production.connection",
                    probe.productionConnectionCount,
                    id: "debug.probe.production-connection"
                )
                counter(
                    "production.process",
                    probe.productionProcessCount,
                    id: "debug.probe.production-process"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var ownerCounters: some View {
        GroupBox("唯一 owner") {
            VStack(alignment: .leading, spacing: 4) {
                owner(.panel, id: "debug.probe.owner-panel")
                owner(.statusItem, id: "debug.probe.owner-status")
                owner(.settings, id: "debug.probe.owner-settings")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var themePreviewSelector: some View {
        GroupBox("六主題 × 六狀態預覽矩陣") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("主題", selection: $selectedThemeID) {
                    ForEach(DebugThemeStatePreviewMatrix.themeIDs, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .accessibilityIdentifier("debug.theme-selector.theme")
                Picker("狀態", selection: $selectedPreviewState) {
                    ForEach(DebugThemePreviewState.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .accessibilityIdentifier("debug.theme-selector.state")
                Text("\(selectedThemeID):\(selectedPreviewState.rawValue)")
                    .accessibilityIdentifier("debug.theme-selector.selection")
                ThemePreviewView(
                    theme: ThemeViewSupport.builtInTheme(
                        for: selectedThemeID
                    ).document,
                    availability:
                        selectedPreviewState.themeAvailabilityState,
                    health: previewHealth
                )
                .id("\(selectedThemeID):\(selectedPreviewState.rawValue)")
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("debug.theme-renderer")
                Text("矩陣共 \(DebugThemeStatePreviewMatrix.all.count) 種")
                    .accessibilityIdentifier("debug.theme-selector.count")
            }
        }
    }

    private var previewHealth: ThemeHealthState? {
        switch selectedPreviewState {
        case .fresh: .healthy
        case .partial, .stale: .warning
        case .loading, .unsupported, .error: nil
        }
    }

    private func counter(
        _ label: String,
        _ value: Int,
        id: String
    ) -> some View {
        Text("\(label)=\(value)")
            .font(.caption.monospacedDigit())
            .accessibilityIdentifier(id)
    }

    private func owner(
        _ kind: AppLifecycleOwnerKind,
        id: String
    ) -> some View {
        Text("\(kind.rawValue).count=\(probe.ownerCount(kind))")
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier(id)
    }
}
#endif
