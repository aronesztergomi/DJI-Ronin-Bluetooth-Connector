import Foundation
import RS3Kit

/// The opaque Rust handle, safe to pass between threads.
struct GimbalHandle: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer
}

let logURL = FileManager.default
    .homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/RoninStudio.log")
private let sessionLogQueue = DispatchQueue(label: "co.rs3studio.session-log")

/// Append to the session log, creating ~/Library/Logs if necessary. Previous
/// writes silently failed on fresh installs when that directory did not exist.
func log(_ message: String) {
    let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    sessionLogQueue.async {
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: logURL.path) {
                let file = try FileHandle(forWritingTo: logURL)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: data)
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            let diagnostic = "Ronin Studio log write failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
    }
}

@MainActor
final class GimbalController: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected(version: String)
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .disconnected: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected(let v): return v
            case .failed(let m): return m
            }
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var deviceName = "No gimbal"
    @Published var panTiltSpeed: Double = 0.85
    @Published var lockPan = false
    @Published var lockTilt = false

    private var handle: GimbalHandle?
    private let queue = DispatchQueue(label: "co.rs3studio.gimbal")
    private var holdTimer: Timer?
    private var remoteTimeout: DispatchWorkItem?
    private var remoteDiagnosticsEnabled = false
    private var stick: (x: Double, y: Double) = (0, 0)
    private var healthTimer: Timer?

    private var speedUnits: Int16 { Int16(200 + panTiltSpeed * 1000) }

    static func rendering() -> GimbalController {
        let c = GimbalController()
        c.state = .connected(version: "GB52 (7.9.0.2)")
        c.deviceName = "DJI RS3-081GWN"
        return c
    }

    func connect() {
        log("connect: requested, state=\(state.label)")
        switch state {
        case .connecting, .connected: return
        case .disconnected, .failed: break
        }
        state = .connecting
        queue.async { [weak self] in
            let h = rs3_connect()
            guard let h else {
                log("connect: no gimbal found")
                Task { @MainActor in self?.state = .failed("No gimbal found") }
                return
            }
            rs3_set_keepalive(h, 500)
            var buf = [CChar](repeating: 0, count: 128)
            let rc = rs3_version(h, &buf, buf.count)
            let version = rc == RS3_OK.rawValue ? String(cString: buf) : "Connected"
            var nameBuf = [CChar](repeating: 0, count: 128)
            let nameRC = rs3_name(h, &nameBuf, nameBuf.count)
            let name = nameRC == RS3_OK.rawValue ? String(cString: nameBuf) : "DJI RS gimbal"
            let handle = GimbalHandle(raw: h)
            Task { @MainActor in
                guard let self else { rs3_disconnect(handle.raw); return }
                self.handle = handle
                self.deviceName = name
                self.state = .connected(version: version)
                log("connect: \(name) \(version)")
                self.watchLink()
            }
        }
    }

    func disconnect() {
        holdTimer?.invalidate()
        remoteTimeout?.cancel()
        healthTimer?.invalidate()
        guard let h = handle else { state = .disconnected; return }
        handle = nil
        state = .disconnected
        deviceName = "No gimbal"
        queue.async { rs3_disconnect(h.raw) }
    }

    private func watchLink() {
        healthTimer?.invalidate()
        healthTimer = everyTick(2.0) { [weak self] in
            guard let self, let h = self.handle else { return }
            self.queue.async {
                guard rs3_is_healthy(h.raw) != 1 else { return }
                log("link lost")
                Task { @MainActor in self.disconnect() }
            }
        }
    }

    private func everyTick(_ interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in Task { @MainActor in body() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func beginMove(_ direction: Direction) {
        guard handle != nil, isAllowed(direction) else { return }
        startSending { [weak self] in self?.mapDirection(direction) }
    }

    func setStick(x: Double, y: Double) {
        guard handle != nil else { return }
        stick = (x, y)
        if holdTimer == nil { startSending { [weak self] in self?.stickSpeeds() } }
    }

    /// Apply normalized WebSocket pan/tilt values. On this gimbal the physical
    /// pan and tilt axes correspond to the library's pitch and yaw outputs,
    /// respectively, so remote controls are intentionally mapped cross-axis.
    /// Returns false if there is no live gimbal handle. Remote streams stop if
    /// updates cease for 600 ms.
    @discardableResult
    func setRemotePanTilt(pan: Double, tilt: Double, panLimit: Double, tiltLimit: Double,
                          diagnostics: Bool = false) -> Bool {
        guard handle != nil else {
            if diagnostics { log("websocket: motion ignored because the gimbal is not connected") }
            return false
        }
        remoteDiagnosticsEnabled = diagnostics
        let boundedPan = min(1, max(-1, pan)) * min(1, max(0, panLimit))
        let boundedTilt = min(1, max(-1, tilt)) * min(1, max(0, tiltLimit))
        startSending { [weak self] in
            self?.remotePanTiltSpeeds(pan: boundedPan, tilt: boundedTilt)
        }
        remoteTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.stopRemoteMotion() }
        remoteTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: timeout)
        return true
    }

    /// Convert semantic remote axes to the physical axes observed on hardware.
    /// Keep the Preferences locks aligned with their semantic pan/tilt axes.
    private func remotePanTiltSpeeds(pan: Double, tilt: Double) -> (yaw: Int16, roll: Int16, pitch: Int16) {
        let magnitude = Double(speedUnits)
        let yaw = lockTilt ? 0 : Int16(clamping: Int(tilt * magnitude))
        let pitch = lockPan ? 0 : Int16(clamping: Int(pan * magnitude))
        return (yaw, 0, pitch)
    }

    func stopRemoteMotion() {
        remoteTimeout?.cancel()
        remoteTimeout = nil
        remoteDiagnosticsEnabled = false
        stick = (0, 0)
        endMove()
    }

    func releaseStick() { stick = (0, 0); endMove() }

    private func stickSpeeds() -> (yaw: Int16, roll: Int16, pitch: Int16) {
        let m = Double(speedUnits)
        let yaw = lockPan ? 0 : Int16(clamping: Int(stick.x * m))
        let pitch = lockTilt ? 0 : Int16(clamping: Int(stick.y * m))
        return (yaw, 0, pitch)
    }

    private func mapDirection(_ direction: Direction) -> (yaw: Int16, roll: Int16, pitch: Int16)? {
        direction.speeds(magnitude: speedUnits)
    }

    private func startSending(_ next: @escaping @MainActor () -> (yaw: Int16, roll: Int16, pitch: Int16)?) {
        holdTimer?.invalidate()
        let tick: @MainActor () -> Void = { [weak self] in
            guard let self, let h = self.handle, let s = next() else { return }
            self.send(s, handle: h, reportErrors: self.remoteDiagnosticsEnabled)
        }
        tick()
        holdTimer = everyTick(0.1) { tick() }
    }

    func endMove() {
        holdTimer?.invalidate()
        holdTimer = nil
        guard let h = handle else { return }
        queue.async { _ = rs3_stop(h.raw) }
    }

    func recenter() {
        guard let h = handle else { return }
        queue.async { _ = rs3_recenter(h.raw) }
    }

    func stop() { endMove() }

    func goTo(_ position: Preset.Position) {
        guard let h = handle else { return }
        queue.async { _ = rs3_goto(h.raw, position.yaw, position.roll, position.pitch) }
    }

    private func isAllowed(_ direction: Direction) -> Bool {
        switch direction {
        case .left, .right: return !lockPan
        case .up, .down: return !lockTilt
        case .rollLeft, .rollRight: return true
        }
    }

    private func send(_ s: (yaw: Int16, roll: Int16, pitch: Int16), handle h: GimbalHandle,
                      reportErrors: Bool) {
        let (yaw, roll, pitch) = s
        queue.async {
            let result = rs3_speed(h.raw, yaw, roll, pitch)
            if reportErrors && result != RS3_OK.rawValue {
                log("websocket: gimbal speed command failed with status \(result) (yaw=\(yaw), roll=\(roll), pitch=\(pitch))")
            }
        }
    }
}

enum Direction: Int32 {
    case left = 0, right = 1, up = 2, down = 3, rollLeft = 4, rollRight = 5
    var raw: Int32 { rawValue }
    func speeds(magnitude m: Int16) -> (yaw: Int16, roll: Int16, pitch: Int16) {
        switch self {
        case .left: return (-m, 0, 0)
        case .right: return (m, 0, 0)
        case .up: return (0, 0, m)
        case .down: return (0, 0, -m)
        case .rollLeft: return (0, -m, 0)
        case .rollRight: return (0, m, 0)
        }
    }
}
