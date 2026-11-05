import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var websocket: WebSocketController
    @EnvironmentObject private var osc: OSCController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Preferences")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)

                GroupBox("WebSocket bridge") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Enable WebSocket listener", isOn: $websocket.enabled)
                        portField("Port", value: $websocket.port, placeholder: "81")
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
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Token authentication is disabled. Any client able to reach this port can send motion commands; use only on a trusted network.")
                                .font(.callout).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("Log WebSocket diagnostics", isOn: $websocket.loggingEnabled)
                        Text("Diagnostics are written to ~/Library/Logs/RoninStudio-WebSocket.log.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(websocket.status)
                            .font(.callout)
                            .foregroundStyle(websocket.isListening ? .green : .secondary)
                    }
                    .padding(8)
                }

                GroupBox("OSC bridge") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Enable OSC listener", isOn: $osc.enabled)
                        portField("UDP port", value: $osc.port, placeholder: "8000")
                        Toggle("Log OSC diagnostics", isOn: $osc.loggingEnabled)
                        Text("OSC diagnostics are written separately to ~/Library/Logs/RoninStudio-OSC.log. OSC has no authentication; use only on a trusted network.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(osc.status)
                            .font(.callout)
                            .foregroundStyle(osc.isListening ? .green : .secondary)
                    }
                    .padding(8)
                }

                GroupBox("Remote motion limits") {
                    VStack(alignment: .leading, spacing: 14) {
                        limitSlider("Maximum pan command", value: $websocket.panLimit)
                        limitSlider("Maximum tilt command", value: $websocket.tiltLimit)
                        Text("These global limits apply to both WebSocket and OSC input. They cap command strength independently on each axis; they are not physical angle or travel stops.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                }
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func portField(_ title: String, value: Binding<Int>, placeholder: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, value: value, format: .number)
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
        }
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
