import SwiftUI

/// Every number in this file was measured off the reference screenshot, which
/// is a 2x capture — so a value of 44 here is 88 px there. They are written as
/// literals rather than derived from each other because the original is not
/// symmetric: the lock chips sit at different offsets, the slider card has
/// 15pt of leading padding against 21pt trailing, and most cards place their
/// contents a little above centre. Deriving would be tidier and wrong.
enum Pixel {
    static let card = Color(white: 247.0 / 255)
    /// The pale disc behind the d-pad.
    static let well = Color(white: 238.0 / 255)
    /// Arrow, lock and roll buttons. Translucent, because they overlap the
    /// well: this composites to 228 over the card and 221 over the well,
    /// which is what the reference does.
    static let control = Color(white: 161.0 / 255).opacity(0.2222)
    static let action = Color(white: 233.0 / 255)
    static let chipStroke = Color(white: 234.0 / 255)

    static let cardRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 6.5
    static let actionRadius: CGFloat = 8

    static let labelSize: CGFloat = 11
    static let columnWidth: CGFloat = 146
    static let sliderWidth: CGFloat = 242
    static let columnGap: CGFloat = 27
    static var contentWidth: CGFloat { columnWidth + columnGap + sliderWidth }
}

/// The Motion pane: directional pad, roll, speed, action buttons.
struct MotionView: View {
    @EnvironmentObject private var gimbal: GimbalController

    var body: some View {
        ScrollView {
            MotionContent()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The pane without its scroll view, so it can also be rendered offscreen for
/// measurement — `ImageRenderer` draws nothing for a `ScrollView`.
struct MotionContent: View {
    @EnvironmentObject private var gimbal: GimbalController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: Pixel.columnGap) {
                    VStack(spacing: 12) {
                        DirectionPad()
                        RollControl()
                    }
                    SpeedSlider(title: "Pan/Tilt Speed", value: $gimbal.panTiltSpeed)
                }

                ActionGrid()
            }
            // One gate for everything that needs a gimbal. Controls that look
            // live but do nothing read as a broken app, so the whole pane
            // dims when there is nothing to drive — the reference screenshot
            // is the connected state, which still matches exactly.
            .disabled(!gimbal.state.isConnected)
            .opacity(gimbal.state.isConnected ? 1 : 0.4)
        }
        .frame(width: Pixel.contentWidth)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text("Motion Control")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Spacer()
            ConnectionBadge()
        }
        .frame(width: Pixel.contentWidth)
    }
}

// MARK: - Directional pad

struct DirectionPad: View {
    @EnvironmentObject private var gimbal: GimbalController

    var body: some View {
        ZStack {
            Circle()
                .fill(Pixel.well)
                .frame(width: 90, height: 90)

            PadButton(icon: "chevron.up", direction: .up, size: CGSize(width: 44, height: 30))
                .offset(y: -44)
            PadButton(icon: "chevron.down", direction: .down, size: CGSize(width: 44, height: 30))
                .offset(y: 44)
            PadButton(icon: "chevron.left", direction: .left, size: CGSize(width: 30, height: 44))
                .offset(x: -45)
            PadButton(icon: "chevron.right", direction: .right, size: CGSize(width: 30, height: 44))
                .offset(x: 45)

            LockToggle(isOn: $gimbal.lockTilt, help: "Lock tilt")
                .offset(x: 34, y: -40)
            LockToggle(isOn: $gimbal.lockPan, help: "Lock pan")
                .offset(x: -39, y: 35)

            Joystick()
        }
        .frame(width: Pixel.columnWidth, height: 141)
        .background(RoundedRectangle(cornerRadius: Pixel.cardRadius).fill(Pixel.card))
    }
}

/// Press and hold to move; release to stop.
struct PadButton: View {
    @EnvironmentObject private var gimbal: GimbalController
    let icon: String
    let direction: Direction
    var size = CGSize(width: 30, height: 44)

    @State private var pressed = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: Pixel.buttonRadius)
                    .fill(pressed ? Color.accentColor.opacity(0.3) : Pixel.control)
            )
            .contentShape(RoundedRectangle(cornerRadius: Pixel.buttonRadius))
            .gesture(
                // A drag with zero distance fires on press, which is what
                // makes hold-to-move feel responsive. onTapGesture would only
                // fire on release.
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        gimbal.beginMove(direction)
                    }
                    .onEnded { _ in
                        pressed = false
                        gimbal.endMove()
                    }
            )
    }
}

/// Analog stick: drag for proportional pan/tilt, release to centre and stop.
///
/// Distance from the centre sets the speed, so small movements are slow and
/// precise. The grab area is 56pt — bigger than the thumb so it is easy to
/// catch, small enough to clear the arrow buttons, whose inner edges are
/// 58.5pt apart.
struct Joystick: View {
    @EnvironmentObject private var gimbal: GimbalController

    private let grab: CGFloat = 56
    private let thumb: CGFloat = 29
    /// Travel of the thumb from the centre. The well is 90pt across.
    private let travel: CGFloat = 30

    @State private var offset: CGSize = .zero
    @State private var dragging = false

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: thumb, height: thumb)
            .shadow(color: .black.opacity(dragging ? 0.22 : 0.15),
                    radius: dragging ? 6 : 4, y: 3)
            .offset(offset)
            .frame(width: grab, height: grab)
            .contentShape(Circle())
            .animation(.interactiveSpring(response: 0.22), value: offset)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        // Measured from the grab circle's centre, so pressing
                        // anywhere inside it takes the thumb to that point.
                        let dx = value.location.x - grab / 2
                        let dy = value.location.y - grab / 2
                        let len = sqrt(dx * dx + dy * dy)
                        let scale = len > travel ? travel / len : 1
                        offset = CGSize(width: dx * scale, height: dy * scale)
                        gimbal.setStick(x: Double(offset.width / travel),
                                        y: Double(-offset.height / travel))
                    }
                    .onEnded { _ in
                        dragging = false
                        offset = .zero
                        gimbal.releaseStick()
                    }
            )
            .help("Drag to pan and tilt; release to stop")
    }
}

struct LockToggle: View {
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "lock.fill" : "lock")
                .font(.system(size: 9))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: Pixel.buttonRadius)
                        .fill(isOn ? Color.accentColor.opacity(0.3) : Pixel.control)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct RollControl: View {
    var body: some View {
        ZStack {
            PadButton(icon: "chevron.left", direction: .rollLeft).offset(x: -45)
            Text("Roll")
                .font(.system(size: Pixel.labelSize))
                .foregroundStyle(.secondary)
            PadButton(icon: "chevron.right", direction: .rollRight).offset(x: 45)
        }
        // The buttons sit 17pt from the top and 20.5pt from the bottom in the
        // reference, not centred.
        .padding(.top, 17)
        .padding(.bottom, 20.5)
        .frame(width: Pixel.columnWidth, height: 81)
        .background(RoundedRectangle(cornerRadius: Pixel.cardRadius).fill(Pixel.card))
    }
}

// MARK: - Speed

struct SpeedSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7.5) {
            HStack(spacing: 7) {
                SpeedChip(icon: "tortoise.fill")
                Slider(value: $value, in: 0...1)
                SpeedChip(icon: "hare.fill")
            }
            .frame(height: 20)
            .padding(.leading, 15)
            .padding(.trailing, 21)
            .padding(.top, 7)
            .frame(width: Pixel.sliderWidth, height: 44, alignment: .top)
            .background(RoundedRectangle(cornerRadius: Pixel.cardRadius).fill(Pixel.card))

            Text(title)
                .font(.system(size: Pixel.labelSize))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .frame(width: Pixel.sliderWidth, alignment: .leading)
    }
}

/// The tortoise/hare markers. Outline only — the fill is the card's.
struct SpeedChip: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 11))
            .foregroundStyle(Color.accentColor)
            .frame(width: 22, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Pixel.chipStroke, lineWidth: 1)
            )
    }
}

// MARK: - Action buttons

struct ActionGrid: View {
    @EnvironmentObject private var gimbal: GimbalController

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ActionButton(icon: "person.crop.square", title: "Active Track", verified: false) {}
            ActionButton(icon: "arrow.counterclockwise", title: "Recenter", verified: true) {
                gimbal.recenter()
            }
            ActionButton(icon: "gearshape.2", title: "Motor Calib", verified: false) {}
            ActionButton(icon: "moon.fill", title: "Sleep", verified: false) {}
            ActionButton(icon: "sun.max", title: "Wake Up", verified: false) {}
            ActionButton(icon: "waveform.path.ecg", title: "AutoTune", verified: false) {}
        }
        .padding(.leading, 11)
        .padding(.trailing, 23)
        .padding(.top, 13)
        .padding(.bottom, 14)
        .frame(width: Pixel.contentWidth)
        .background(RoundedRectangle(cornerRadius: Pixel.cardRadius).fill(Pixel.card))
    }
}

struct ActionButton: View {
    let icon: String
    let title: String
    /// Whether the underlying command has been confirmed on hardware.
    let verified: Bool
    let action: () -> Void

    var body: some View {
        // Buttons whose command has not been identified keep the reference's
        // appearance rather than being dimmed, so they are inert with a
        // tooltip that says why instead of looking broken.
        Button(action: verified ? action : {}) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13.5))
                Text(title).font(.system(size: Pixel.labelSize))
            }
            .foregroundStyle(.primary)
            .frame(height: 35)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Pixel.actionRadius).fill(Pixel.action))
        }
        .buttonStyle(.plain)
        // Same reasoning as the pane-wide gate: a button that looks ready and
        // does nothing is worse than one that shows it is not wired up.
        .disabled(!verified)
        .opacity(verified ? 1 : 0.45)
        .help(verified ? title : "\(title): command not yet identified")
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject private var gimbal: GimbalController

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColour)
                .frame(width: 8, height: 8)
            Text(gimbal.state.label)
                .font(.system(size: Pixel.labelSize))
                .foregroundStyle(.secondary)

            switch gimbal.state {
            case .connected:
                Button("Disconnect", action: gimbal.disconnect)
            case .connecting:
                ProgressView().controlSize(.small)
            default:
                Button("Connect", action: gimbal.connect)
            }
        }
    }

    private var dotColour: Color {
        switch gimbal.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }
}
