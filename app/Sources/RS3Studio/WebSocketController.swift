import Foundation
import Network
import SwiftUI

/// WebSocket ingress for remote pan/tilt control. Messages are intentionally
/// small text frames; when access-token protection is enabled, each connection
/// must authenticate before sending motion commands.
@MainActor
final class WebSocketController: ObservableObject {
    @Published var enabled: Bool { didSet { persist(); if !isApplying { applySettings() } } }
    @Published var port: Int { didSet { persist(); if !isApplying { applySettings() } } }
    @Published var requireAccessToken: Bool { didSet { persist(); if !isApplying { applySettings() } } }
    @Published var panLimit: Double { didSet { persist() } }
    @Published var tiltLimit: Double { didSet { persist() } }
    @Published var loggingEnabled: Bool { didSet { persist() } }
    @Published private(set) var isListening = false
    @Published private(set) var status = "Stopped"

    private let gimbal: GimbalController
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "co.rs3studio.websocket")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var isApplying = false

    var token: String {
        if let value = defaults.string(forKey: Keys.token), !value.isEmpty { return value }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defaults.set(value, forKey: Keys.token)
        return value
    }

    init(gimbal: GimbalController) {
        self.gimbal = gimbal
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        port = defaults.object(forKey: Keys.port) as? Int ?? 81
        requireAccessToken = defaults.object(forKey: Keys.requireAccessToken) as? Bool ?? true
        panLimit = defaults.object(forKey: Keys.panLimit) as? Double ?? 1.0
        tiltLimit = defaults.object(forKey: Keys.tiltLimit) as? Double ?? 1.0
        loggingEnabled = defaults.object(forKey: Keys.loggingEnabled) as? Bool ?? false
    }

    func applySettings() {
        stop()
        guard enabled else { return }
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            status = "Invalid port"
            wsLog("invalid port setting: \(port)")
            return
        }
        do {
            let parameters = NWParameters.tcp
            let websocket = NWProtocolWebSocket.Options()
            websocket.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
            let newListener = try NWListener(using: parameters, on: nwPort)
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isListening = true
                        self?.status = "Listening on port \(self?.port ?? 0)"
                        self?.wsLog("listener ready on port \(self?.port ?? 0)")
                    case .failed(let error):
                        self?.isListening = false
                        self?.status = "Listener error: \(error.localizedDescription)"
                        self?.wsLog("listener failed: \(error.localizedDescription)")
                    case .cancelled:
                        self?.isListening = false
                        self?.status = "Stopped"
                        self?.wsLog("listener cancelled")
                    default: break
                    }
                }
            }
            listener = newListener
            newListener.start(queue: queue)
            status = "Starting…"
            wsLog("starting listener on port \(port)")
        } catch {
            status = "Could not listen: \(error.localizedDescription)"
            wsLog("failed to create listener on port \(port): \(error.localizedDescription)")
        }
    }

    func stop() {
        if listener != nil { wsLog("stopping listener") }
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        isListening = false
        status = "Stopped"
        gimbal.stopRemoteMotion()
    }

    private func persist() {
        guard !isApplying else { return }
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(port, forKey: Keys.port)
        defaults.set(requireAccessToken, forKey: Keys.requireAccessToken)
        defaults.set(panLimit, forKey: Keys.panLimit)
        defaults.set(tiltLimit, forKey: Keys.tiltLimit)
        defaults.set(loggingEnabled, forKey: Keys.loggingEnabled)
    }

    private func wsLog(_ message: String) {
        guard loggingEnabled else { return }
        log("websocket: \(message)")
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        wsLog("accepted connection \(id)")
        connection.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else {
                if case .cancelled = state {
                    Task { @MainActor in
                        self?.wsLog("connection cancelled \(id)")
                        self?.remove(connection, id: id)
                    }
                }
                return
            }
            Task { @MainActor in
                self?.wsLog("connection failed \(id)")
                self?.remove(connection, id: id)
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id, authenticated: false)
    }

    private func remove(_ connection: NWConnection, id: ObjectIdentifier) {
        connections.removeValue(forKey: id)
        connection.cancel()
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier, authenticated: Bool) {
        connection.receiveMessage { [weak self] data, context, _, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.handleMessage(data: data, context: context, error: error,
                                   on: connection, id: id, authenticated: authenticated)
            }
        }
    }

    private func handleMessage(data: Data?, context: NWConnection.ContentContext?, error: NWError?,
                               on connection: NWConnection, id: ObjectIdentifier, authenticated: Bool) {
        if let error {
            wsLog("receive error from \(id): \(error.localizedDescription)")
            remove(connection, id: id)
            return
        }
        guard let data else {
            wsLog("connection \(id) closed without a message")
            remove(connection, id: id)
            return
        }
        guard data.count <= 512 else {
            wsLog("rejected oversized frame from \(id) (\(data.count) bytes)")
            reply("error: frame too large", to: connection)
            remove(connection, id: id)
            return
        }
        guard let text = String(data: data, encoding: .utf8),
              let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
              metadata.opcode == .text else {
            wsLog("rejected non-text or invalid UTF-8 frame from \(id)")
            reply("error: expected text frame", to: connection)
            remove(connection, id: id)
            return
        }

        var isAuthenticated = authenticated
        if requireAccessToken && !isAuthenticated {
            isAuthenticated = text == "auth:\(token)"
            wsLog(isAuthenticated ? "authentication accepted for \(id)" : "authentication rejected for \(id)")
            reply(isAuthenticated ? "ready" : "unauthorized", to: connection)
            if !isAuthenticated {
                remove(connection, id: id)
                return
            }
            receive(on: connection, id: id, authenticated: true)
            return
        }

        // In no-token mode, the first message is a motion command. It does not
        // require an auth frame and subsequent commands are handled identically.
        isAuthenticated = true
        if let command = Self.parse(text) {
            let limits = currentLimits
            wsLog("command accepted from \(id): pan=\(command.pan), tilt=\(command.tilt), limits=(pan \(limits.pan), tilt \(limits.tilt)), gimbalConnected=\(gimbal.state.isConnected)")
            gimbal.setRemotePanTilt(pan: command.pan, tilt: command.tilt,
                                    panLimit: limits.pan, tiltLimit: limits.tilt)
            reply("ok", to: connection)
        } else {
            wsLog("rejected command from \(id): expected pan:X tilt:Y; received \(text.prefix(160))")
            reply("error: expected pan:X tilt:Y", to: connection)
        }
        receive(on: connection, id: id, authenticated: isAuthenticated)
    }

    private var currentLimits: (pan: Double, tilt: Double) {
        (min(1, max(0, panLimit)), min(1, max(0, tiltLimit)))
    }

    private func reply(_ text: String, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "websocket-text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor in self?.wsLog("failed to send response: \(error.localizedDescription)") }
            }
        })
    }

    private nonisolated static func parse(_ message: String) -> (pan: Double, tilt: Double)? {
        let tokens = message.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard tokens.count == 2 else { return nil }
        var values: [String: Double] = [:]
        for token in tokens {
            let pair = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let value = Double(pair[1]), value.isFinite else { return nil }
            let key = pair[0].lowercased()
            guard (key == "pan" || key == "tilt"), values[key] == nil else { return nil }
            values[key] = value
        }
        guard let pan = values["pan"], let tilt = values["tilt"] else { return nil }
        return (min(1, max(-1, pan)), min(1, max(-1, tilt)))
    }

    private enum Keys {
        static let enabled = "rs3.websocket.enabled"
        static let port = "rs3.websocket.port"
        static let requireAccessToken = "rs3.websocket.requireAccessToken"
        static let panLimit = "rs3.websocket.panLimit"
        static let tiltLimit = "rs3.websocket.tiltLimit"
        static let loggingEnabled = "rs3.websocket.loggingEnabled"
        static let token = "rs3.websocket.token"
    }
}
