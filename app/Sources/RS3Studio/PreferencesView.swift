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
                        HStack(alignment: .top) {
                            Text("Access token")
                            Spacer()
                            Text(websocket.token)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: 310, alignment: .trailing)
                        }
                        Text(websocket.status)
                            .font(.callout)
                            .foregroundStyle(websocket.isListening ? .green : .secondary)
                        Text("The listener accepts connections on this Mac's network interfaces. Authenticate each connection by sending auth:<token> as the first text message.")
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
                        Text("Limits cap command strength independently on each axis. They are normalized speed limits, not physical angle or travel stops; the gimbal does not provide position feedback for enforcing angular boundaries.")
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
