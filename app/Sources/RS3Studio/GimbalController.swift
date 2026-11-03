import Foundation
import RS3Kit

/// The opaque Rust handle, safe to pass between threads.
struct GimbalHandle: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer
}

let logURL = FileManager.default
    .homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/RoninStudio.log")

func log(_ message: String) {
    let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    } else {
        try? data.write(to: logURL)
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

    /// Apply a normalized remote command after enforcing independent per-axis
    /// maximum magnitudes. Remote streams stop if updates cease for 600 ms.
    func setRemotePanTilt(pan: Double, tilt: Double, panLimit: Double, tiltLimit: Double) {
        guard handle != nil else { return }
        let x = min(1, max(-1, pan)) * min(1, max(0, panLimit))
        let y = min(1, max(-1, tilt)) * min(1, max(0, tiltLimit))
        setStick(x: x, y: y)
        remoteTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.stopRemoteMotion() }
        remoteTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: timeout)
    }

    func stopRemoteMotion() {
        remoteTimeout?.cancel()
        remoteTimeout = nil
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
            self.send(s, handle: h)
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

    private func send(_ s: (yaw: Int16, roll: Int16, pitch: Int16), handle h: GimbalHandle) {
        let (yaw, roll, pitch) = s
        queue.async { _ = rs3_speed(h.raw, yaw, roll, pitch) }
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
