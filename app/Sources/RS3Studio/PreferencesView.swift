import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var websocket: WebSocketController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Preferences")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)

                GroupBox("WebSocket bridge") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Enable WebSocket listener", isOn: $websocket.enabled)
                        HStack {
                            Text("Port")
                            Spacer()
                            TextField("81", value: $websocket.port, format: .number)
                                .frame(width: 90)
                                .textFieldStyle(.roundedBorder)
                        }
                        Toggle("Require access token", isOn: $websocket.requireAccessToken)
                        if websocket.requireAccessToken {
                            HStack(alignment: .top) {
                                Text("Access token")
                                Spacer()
                                Text(websocket.token)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: 310, alignment: .trailing)
                            }
                            Text("Send auth:<token> as the first text message on each connection.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Token authentication is disabled. Any client able to reach this port can send motion commands; use only on a trusted network.")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("Log WebSocket diagnostics", isOn: $websocket.loggingEnabled)
                        Text("When enabled, connection, authentication, command, and network errors are appended to ~/Library/Logs/RoninStudio.log.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(websocket.status)
                            .font(.callout)
                            .foregroundStyle(websocket.isListening ? .green : .secondary)
                        Text("The listener accepts connections on this Mac's network interfaces.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                }

                GroupBox("Remote motion limits") {
                    VStack(alignment: .leading, spacing: 14) {
                        limitSlider("Maximum pan command", value: $websocket.panLimit)
                        limitSlider("Maximum tilt command", value: $websocket.tiltLimit)
                        Text("Limits cap command strength independently on each axis. They are normalized speed limits, not physical angle or travel stops; the gimbal does not provide position feedback needed to guarantee angular boundaries.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                }
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func limitSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1, step: 0.01)
        }
    }
}
