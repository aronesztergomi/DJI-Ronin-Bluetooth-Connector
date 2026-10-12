import AppKit
import SwiftUI

/// An app assembled by hand around a SwiftPM executable does not get the
/// activation a Finder-launched, Xcode-built app does: it starts in the
/// background with no window brought forward. Force it to behave like a normal
/// GUI app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        log("app: launched")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first else { return }
        window.makeKeyAndOrderFront(nil)
        if Demo.isOn {
            // A size the content actually fills, so screenshots are not
            // mostly empty window.
            window.setContentSize(NSSize(width: 700, height: 530))
            window.center()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// `--demo [pane]` brings the window up with a stand-in gimbal and sample
/// presets, and never opens a Bluetooth link. It is how the screenshots are
/// taken, and it is the only way to see the connected layout without hardware.
enum Demo {
    static let isOn = CommandLine.arguments.contains("--demo")

    static var pane: Pane {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo"), i + 1 < args.count,
              let p = Pane(rawValue: args[i + 1]) else { return .motion }
        return p
    }
}

@main
struct RS3StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var gimbal = Demo.isOn ? .rendering() : GimbalController()
    @StateObject private var presets = Demo.isOn ? .rendering() : PresetStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(gimbal)
                .environmentObject(presets)
                .frame(minWidth: 700, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Connect") { gimbal.connect() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Stop Motion") { gimbal.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case motion = "Motion"
    case presets = "Presets"
    case preferences = "Preferences"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .motion: return "dot.circle.and.hand.point.up.left.fill"
        case .presets: return "mappin.and.ellipse"
        case .preferences: return "gearshape.2"
        }
    }

    /// Panes with nothing behind them yet are shown but not selectable.
    var implemented: Bool {
        self == .motion || self == .presets || self == .overview
    }
}

struct RootView: View {
    @EnvironmentObject private var gimbal: GimbalController
    @State private var pane: Pane = Demo.pane

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section("Control") {
                    ForEach(Pane.allCases) { p in
                        Label(p.rawValue, systemImage: p.icon)
                            .tag(p)
                            .foregroundStyle(p.implemented ? .primary : .tertiary)
                    }
                }
                Section("Controllers") {
                    Text("None").foregroundStyle(.tertiary).font(.callout)
                }
                Section("Gimbals") {
                    GimbalSidebarRow()
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            switch pane {
            case .motion: MotionView()
            case .presets: PresetsView()
            case .overview: OverviewView()
            default: Placeholder(name: pane.rawValue)
            }
        }
        .onAppear { gimbal.connect() }
    }
}

struct GimbalSidebarRow: View {
    @EnvironmentObject private var gimbal: GimbalController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gyroscope")
            VStack(alignment: .leading, spacing: 1) {
                Text(gimbal.deviceName)
                    .font(.callout)
                if case .connected(let v) = gimbal.state {
                    Text(v).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if gimbal.state.isConnected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
            }
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject private var gimbal: GimbalController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Overview")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ConnectionBadge()
                }

                GroupBox("Gimbal") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Status", gimbal.state.label)
                        row("Transport", "Bluetooth LE · DUML over GATT fff0")
                    }
                    .padding(8)
                }

                GroupBox("What works") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Directional control", "Verified on hardware")
                        row("Recenter", "Implemented")
                        row("Absolute positioning", "Unverified — payload layout inferred")
                        row("Zoom, Active Track, Sleep", "Not yet identified")
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
            Text(v)
            Spacer()
        }
        .font(.callout)
    }
}

struct Placeholder: View {
    let name: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(name).font(.title2)
            Text("Not implemented.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
