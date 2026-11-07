import Foundation
import Network
import SwiftUI

/// OSC/UDP ingress for remote pan/tilt control. Each datagram contains one OSC
/// message whose address is `/pan`, `/tilt`, or `/panTilt` (two arguments).
@MainActor
final class OSCController: ObservableObject {
    @Published var enabled: Bool { didSet { persist(); if !isApplying { applySettings() } } }
    @Published var port: Int { didSet { persist(); if !isApplying { applySettings() } } }
    @Published var loggingEnabled: Bool {
        didSet {
            persist()
            if loggingEnabled { oscLog("diagnostics logging enabled") }
        }
    }
    @Published private(set) var isListening = false
    @Published private(set) var status = "Stopped"

    private let gimbal: GimbalController
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "co.rs3studio.osc")
    private var listener: NWListener?
    private var listenerID: UUID?
    private var isApplying = false

    private var diagnosticLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RoninStudio-OSC.log")
    }

    init(gimbal: GimbalController) {
        self.gimbal = gimbal
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        port = defaults.object(forKey: Keys.port) as? Int ?? 8000
        loggingEnabled = defaults.object(forKey: Keys.loggingEnabled) as? Bool ?? false
    }

    func applySettings() {
        guard enabled else { stop(); return }
        if let listener {
            status = "Restarting listener…"
            oscLog("restart requested; waiting for current listener to cancel")
            listener.cancel()
            return
        }
        startListener()
    }

    private func startListener() {
        guard enabled, listener == nil else { return }
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            status = "Invalid port"
            oscLog("invalid port setting: \(port)")
            return
        }
        do {
            let newListener = try NWListener(using: .udp, on: nwPort)
            let id = UUID()
            listener = newListener
            listenerID = id
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listenerID == id else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.status = "Listening on UDP port \(self.port)"
                        self.oscLog("listener ready on UDP port \(self.port)")
                    case .failed(let error):
                        self.isListening = false
                        self.status = "Listener error: \(error.localizedDescription)"
                        self.oscLog("listener failed: \(error.localizedDescription)")
                        self.listener = nil
                        self.listenerID = nil
                    case .cancelled:
                        self.isListening = false
                        self.listener = nil
                        self.listenerID = nil
                        self.oscLog("listener cancelled")
                        if self.enabled { self.startListener() }
                        else { self.status = "Stopped" }
                    default: break
                    }
                }
            }
            status = "Starting…"
            oscLog("starting UDP listener on port \(port)")
            newListener.start(queue: queue)
        } catch {
            status = "Could not listen: \(error.localizedDescription)"
            oscLog("failed to create listener on port \(port): \(error.localizedDescription)")
        }
    }

    func stop() {
        if listener != nil {
            status = "Stopping…"
            oscLog("stopping listener")
            listener?.cancel()
        } else {
            status = "Stopped"
        }
        // The shared gimbal motion watchdog stops remote motion after 600 ms
        // without updates. Do not stop it immediately: WebSocket may be active.
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.oscLog("UDP connection failed: \(error.localizedDescription)") }
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                if let error {
                    self.oscLog("receive failed: \(error.localizedDescription)")
                } else if let data {
                    self.handlePacket(data)
                }
                self.receive(on: connection)
            }
        }
    }

    private func handlePacket(_ data: Data) {
        guard data.count <= 1024,
              let command = Self.parse(data) else {
            oscLog("rejected malformed or oversized OSC datagram (\(data.count) bytes)")
            return
        }
        let limits = (pan: min(1, max(0, UserDefaults.standard.double(forKey: "rs3.websocket.panLimit"))),
                      tilt: min(1, max(0, UserDefaults.standard.double(forKey: "rs3.websocket.tiltLimit"))))
        let pan = command.pan ?? 0
        let tilt = command.tilt ?? 0
        let sent = gimbal.setRemotePanTilt(pan: pan, tilt: tilt,
                                           panLimit: limits.pan, tiltLimit: limits.tilt,
                                           diagnostics: loggingEnabled,
                                           source: "osc", diagnosticLogURL: diagnosticLogURL)
        oscLog("command \(command.address): pan=\(pan), tilt=\(tilt), limits=(pan \(limits.pan), tilt \(limits.tilt)), gimbalConnected=\(sent)")
        if !sent { oscLog("motion command not sent: gimbal is not connected") }
    }

    private func persist() {
        guard !isApplying else { return }
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(port, forKey: Keys.port)
        defaults.set(loggingEnabled, forKey: Keys.loggingEnabled)
    }

    private func oscLog(_ message: String) {
        guard loggingEnabled else { return }
        appendLog("osc: \(message)", to: diagnosticLogURL)
    }

    /// Parse a single OSC message using float32, float64, or int32 arguments.
    /// Float inputs are rounded to hundredths and clamped to the shared range.
    private nonisolated static func parse(_ data: Data) -> (pan: Double?, tilt: Double?, address: String)? {
        var cursor = 0
        guard let address = readString(data, cursor: &cursor),
              let tags = readString(data, cursor: &cursor), tags.first == "," else { return nil }
        let types = Array(tags.dropFirst())
        guard ["/pan", "/tilt", "/panTilt"].contains(address) else { return nil }
        let expected = address == "/panTilt" ? 2 : 1
        guard types.count == expected, types.allSatisfy({ $0 == "f" || $0 == "d" || $0 == "i" }) else { return nil }
        var values: [Double] = []
        for type in types {
            switch type {
            case "f":
                guard let bits = readUInt32(data, cursor: &cursor) else { return nil }
                values.append(Double(Float(bitPattern: bits)))
            case "d":
                guard let bits = readUInt64(data, cursor: &cursor) else { return nil }
                values.append(Double(bitPattern: bits))
            case "i":
                guard let bits = readUInt32(data, cursor: &cursor) else { return nil }
                values.append(Double(Int32(bitPattern: bits)))
            default: return nil
            }
        }
        guard cursor == data.count, values.allSatisfy(\.isFinite) else { return nil }
        let normalized = values.map { min(1, max(-1, ($0 * 100).rounded() / 100)) }
        switch address {
        case "/pan": return (normalized[0], nil, address)
        case "/tilt": return (nil, normalized[0], address)
        default: return (normalized[0], normalized[1], address)
        }
    }

    private nonisolated static func readString(_ data: Data, cursor: inout Int) -> String? {
        guard cursor < data.count,
              let end = data[cursor...].firstIndex(of: 0),
              let value = String(data: data[cursor..<end], encoding: .utf8) else { return nil }
        let next = (end + 4) & ~3
        guard next <= data.count else { return nil }
        cursor = next
        return value
    }

    private nonisolated static func readUInt32(_ data: Data, cursor: inout Int) -> UInt32? {
        guard cursor + 4 <= data.count else { return nil }
        let value = data[cursor..<cursor + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        cursor += 4
        return value
    }

    private nonisolated static func readUInt64(_ data: Data, cursor: inout Int) -> UInt64? {
        guard cursor + 8 <= data.count else { return nil }
        let value = data[cursor..<cursor + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        cursor += 8
        return value
    }

    private enum Keys {
        static let enabled = "rs3.osc.enabled"
        static let port = "rs3.osc.port"
        static let loggingEnabled = "rs3.osc.loggingEnabled"
    }
}
