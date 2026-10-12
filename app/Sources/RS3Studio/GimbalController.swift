import Foundation
import RS3Kit

/// The opaque Rust handle, safe to pass between threads.
///
/// `UnsafeMutableRawPointer` is not `Sendable`, but this one is: everything
/// behind it is synchronised on the Rust side (an `Arc<Gimbal>`, a `Mutex` for
/// the keep-alive slot, and a Tokio runtime owned by the handle). We also fence
/// every call onto one serial queue.
struct GimbalHandle: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer
}

/// Observable wrapper around the Rust library.
///
/// Every `rs3_*` call blocks, so they all run on a serial background queue and
/// publish back on the main actor. Connecting in particular scans for several
/// seconds and must never touch the main thread.
/// Session log, appended to `~/Library/Logs/RoninStudio.log`.
///
/// A gimbal app that silently stops responding is miserable to debug from a
/// screenshot. A file rather than os_log because a bundled app's stderr goes
/// nowhere and the unified log swallowed these entirely.
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
    /// What the gimbal calls itself, e.g. "DJI RS3-081GWN".
    @Published private(set) var deviceName = "No gimbal"

    /// Pan/tilt speed, 0...1, mapped onto the gimbal's own units.
    @Published var panTiltSpeed: Double = 0.85

    /// Axes the directional pad will not drive.
    @Published var lockPan = false
    @Published var lockTilt = false

    private var handle: GimbalHandle?
    private let queue = DispatchQueue(label: "co.rs3studio.gimbal")
    private var holdTimer: Timer?
    private var stick: (x: Double, y: Double) = (0, 0)
    private var healthTimer: Timer?

    /// Maps the 0...1 slider onto gimbal speed units. 200 moves slowly but
    /// visibly; 1200 is brisk without being alarming on a balanced rig.
    private var speedUnits: Int16 {
        Int16(200 + panTiltSpeed * 1000)
    }

    /// A controller that reports a link without touching Bluetooth, for
    /// screenshots. See `Demo`.
    static func rendering() -> GimbalController {
        let c = GimbalController()
        c.state = .connected(version: "GB52 (7.9.0.2)")
        c.deviceName = "DJI RS3-081GWN"
        return c
    }

    // MARK: - Connection

    func connect() {
        log("connect: requested, state=\(state.label)")
        // Retry must work after a failure, not just from a clean start.
        switch state {
        case .connecting, .connected: return
        case .disconnected, .failed: break
        }
        state = .connecting
        queue.async { [weak self] in
            let h = rs3_connect()
            guard let h else {
                log("connect: no gimbal found")
                Task { @MainActor in
                    self?.state = .failed("No gimbal found")
                }
                return
            }
            // Hold the session and notice a dropped link promptly.
            rs3_set_keepalive(h, 500)

            var buf = [CChar](repeating: 0, count: 128)
            let rc = rs3_version(h, &buf, buf.count)
            let version = rc == RS3_OK.rawValue ? String(cString: buf) : "Connected"

            var nameBuf = [CChar](repeating: 0, count: 128)
            let nameRC = rs3_name(h, &nameBuf, nameBuf.count)
            let name = nameRC == RS3_OK.rawValue ? String(cString: nameBuf) : "DJI RS gimbal"

            let handle = GimbalHandle(raw: h)

            Task { @MainActor in
                guard let self else {
                    rs3_disconnect(handle.raw)
                    return
                }
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
        healthTimer?.invalidate()
        guard let h = handle else {
            state = .disconnected
            return
        }
        handle = nil
        state = .disconnected
        deviceName = "No gimbal"
        queue.async { rs3_disconnect(h.raw) }
    }

    /// Notice the gimbal going away — switched off, out of range, flat battery.
    ///
    /// The Rust side probes twice a second; this samples the result. There is
    /// no "connected but unhealthy" state worth showing, because nothing we
    /// send arrives either way, so a failed probe just drops the link.
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

    /// A repeating timer that keeps running while the mouse button is held.
    ///
    /// `Timer.scheduledTimer` registers for `.default` only, but AppKit runs
    /// the whole of a mouse drag in `NSEventTrackingRunLoopMode`. A timer
    /// scheduled the usual way therefore stops firing for exactly as long as
    /// the user holds the button down — which is when a hold-to-move control
    /// needs it most. `.common` covers both modes.
    private func everyTick(_ interval: TimeInterval,
                           _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in body() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: - Motion

    /// Begin moving and keep moving until `endMove()`.
    ///
    /// Speed commands express a rate and lapse on their own, so they are
    /// resent on a timer; the gimbal coasts to a stop if we stop talking.
    /// The speeds are recomputed on every tick rather than captured once, so
    /// dragging the speed slider mid-move takes effect immediately.
    func beginMove(_ direction: Direction) {
        log("beginMove \(direction) connected=\(state.isConnected)")
        guard handle != nil, isAllowed(direction) else { return }
        startSending { [weak self] in
            guard let self else { return nil }
            return direction.speeds(magnitude: self.speedUnits)
        }
    }

    /// Continuous control from the joystick.
    ///
    /// `x` and `y` are -1...1 with y positive upward. Called on every drag
    /// change; the resend timer keeps the gimbal moving while the stick is
    /// held still, which it otherwise would not do.
    func setStick(x: Double, y: Double) {
        guard handle != nil else { return }
        stick = (x, y)
        if holdTimer == nil {
            startSending { [weak self] in self?.stickSpeeds() }
        }
    }

    func releaseStick() {
        stick = (0, 0)
        endMove()
    }

    private func stickSpeeds() -> (yaw: Int16, roll: Int16, pitch: Int16) {
        let m = Double(speedUnits)
        let yaw = lockPan ? 0 : Int16(clamping: Int(stick.x * m))
        let pitch = lockTilt ? 0 : Int16(clamping: Int(stick.y * m))
        return (yaw, 0, pitch)
    }

    /// Drive the gimbal from a closure sampled on every tick.
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

    func stop() {
        endMove()
    }

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
