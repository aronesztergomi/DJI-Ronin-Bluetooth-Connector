import Foundation
import Network
import SwiftUI

/// WebSocket ingress for remote pan/tilt control. Messages are intentionally
/// small text frames; a client must authenticate once per connection before
/// sending motion commands.
@MainActor
final class WebSocketController: ObservableObject {
    @Published var enabled: Bool { didSet { persist(); if !isApplying { applySettings() } } }
    @Published var port: Int { didSet { persist(); if !isApplying { applySettings() } } }
    @Published var panLimit: Double { didSet { persist() } }
    @Published var tiltLimit: Double { didSet { persist() } }
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
        panLimit = defaults.object(forKey: Keys.panLimit) as? Double ?? 1.0
        tiltLimit = defaults.object(forKey: Keys.tiltLimit) as? Double ?? 1.0
    }

    func applySettings() {
        stop()
        guard enabled else { return }
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            status = "Invalid port"
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
                    case .failed(let error):
                        self?.isListening = false
                        self?.status = "Listener error: \(error.localizedDescription)"
                        log("websocket: listener failed: \(error)")
                    case .cancelled:
                        self?.isListening = false
                        self?.status = "Stopped"
                    default: break
                    }
                }
            }
            listener = newListener
            newListener.start(queue: queue)
            status = "Starting…"
        } catch {
            status = "Could not listen: \(error.localizedDescription)"
            log("websocket: failed to create listener on port \(port): \(error)")
        }
    }

    func stop() {
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
        defaults.set(panLimit, forKey: Keys.panLimit)
        defaults.set(tiltLimit, forKey: Keys.tiltLimit)
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else {
                if case .cancelled = state {
                    Task { @MainActor in self?.remove(connection, id: id) }
                }
                return
            }
            Task { @MainActor in self?.remove(connection, id: id) }
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
        guard error == nil, let data, data.count <= 512,
              let text = String(data: data, encoding: .utf8),
              let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
              metadata.opcode == .text else {
            remove(connection, id: id)
            return
        }

        var isAuthenticated = authenticated
        if !isAuthenticated {
            isAuthenticated = text == "auth:\(token)"
            reply(isAuthenticated ? "ready" : "unauthorized", to: connection)
            if !isAuthenticated {
                remove(connection, id: id)
                return
            }
        } else if let command = Self.parse(text) {
            let limits = currentLimits
            gimbal.setRemotePanTilt(pan: command.pan, tilt: command.tilt,
                                    panLimit: limits.pan, tiltLimit: limits.tilt)
            reply("ok", to: connection)
        } else {
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
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
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
        static let panLimit = "rs3.websocket.panLimit"
        static let tiltLimit = "rs3.websocket.tiltLimit"
        static let token = "rs3.websocket.token"
    }
}
