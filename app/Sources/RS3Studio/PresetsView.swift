import SwiftUI

/// A stored gimbal position.
struct Preset: Identifiable, Codable, Equatable {
    struct Position: Codable, Equatable {
        var yaw: Int16
        var roll: Int16
        var pitch: Int16

        /// Tenths of a degree, matching the wire format.
        var degrees: (Double, Double, Double) {
            (Double(yaw) / 10, Double(roll) / 10, Double(pitch) / 10)
        }
    }

    var id = UUID()
    var name: String
    var position: Position
}

/// Presets live in the same place the Rust CLI writes them, so the two agree.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [Preset] = []

    private let url: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rs3-studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("presets.csv")
    }()

    init() { load() }

    /// Sample positions for `--demo`, held in memory and never written out.
    static func rendering() -> PresetStore {
        let store = PresetStore()
        store.presets = [
            Preset(name: "Wide", position: .init(yaw: -900, roll: 0, pitch: -100)),
            Preset(name: "Centre", position: .init(yaw: 0, roll: 0, pitch: 0)),
            Preset(name: "Interview", position: .init(yaw: 350, roll: 0, pitch: -55)),
            Preset(name: "Top down", position: .init(yaw: 0, roll: 0, pitch: -900)),
        ]
        return store
    }

    func add(name: String, position: Preset.Position) {
        if let i = presets.firstIndex(where: { $0.name == name }) {
            presets[i].position = position
        } else {
            presets.append(Preset(name: name, position: position))
        }
        save()
    }

    func remove(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    /// `name,yaw,roll,pitch` per line — the same format the Rust side reads.
    private func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        presets = text.split(separator: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 4,
                  let y = Int16(f[1].trimmingCharacters(in: .whitespaces)),
                  let r = Int16(f[2].trimmingCharacters(in: .whitespaces)),
                  let p = Int16(f[3].trimmingCharacters(in: .whitespaces))
            else { return nil }
            return Preset(name: String(f[0]), position: .init(yaw: y, roll: r, pitch: p))
        }
    }

    private func save() {
        var out = "# name,yaw,roll,pitch (tenths of a degree)\n"
        for p in presets {
            out += "\(p.name),\(p.position.yaw),\(p.position.roll),\(p.position.pitch)\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct PresetsView: View {
    @EnvironmentObject private var gimbal: GimbalController
    @EnvironmentObject private var store: PresetStore

    @State private var name = ""
    @State private var yaw = 0.0
    @State private var roll = 0.0
    @State private var pitch = 0.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Presets")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ConnectionBadge()
                }

                Text("Positions are entered rather than captured: this gimbal "
                     + "does not answer attitude queries, so there is no live "
                     + "reading to record.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                        axisField("Yaw", $yaw)
                        axisField("Roll", $roll)
                        axisField("Pitch", $pitch)
                        HStack {
                            Spacer()
                            Button("Add preset") {
                                guard !name.isEmpty else { return }
                                store.add(name: name, position: .init(
                                    yaw: Int16(yaw * 10),
                                    roll: Int16(roll * 10),
                                    pitch: Int16(pitch * 10)
                                ))
                                name = ""
                            }
                            .disabled(name.isEmpty)
                        }
                    }
                    .padding(8)
                }

                if store.presets.isEmpty {
                    Text("No presets yet.").foregroundStyle(.tertiary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(store.presets) { preset in
                            PresetRow(preset: preset)
                        }
                    }
                }
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func axisField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
            Slider(value: value, in: -180...180)
            Text("\(value.wrappedValue, specifier: "%.1f")°")
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
    }
}

struct PresetRow: View {
    @EnvironmentObject private var gimbal: GimbalController
    @EnvironmentObject private var store: PresetStore
    let preset: Preset

    var body: some View {
        let (y, r, p) = preset.position.degrees
        HStack {
            Text(preset.name).font(.system(size: 14, weight: .medium))
            Spacer()
            Text("yaw \(y, specifier: "%.1f")°  roll \(r, specifier: "%.1f")°  pitch \(p, specifier: "%.1f")°")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Go") { gimbal.goTo(preset.position) }
                .disabled(!gimbal.state.isConnected)
                .help("Absolute positioning is not yet confirmed on hardware")
            Button(role: .destructive) { store.remove(preset) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
    }
}
