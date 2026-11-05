## OSC control bridge

Enable the OSC listener in Preferences to receive OSC over UDP (default port `8000`). It is configured independently from WebSocket, and both services can run simultaneously on separate ports. Configure the listener and optional diagnostics logging under Preferences. OSC diagnostic output is written to `~/Library/Logs/RoninStudio-OSC.log`; WebSocket diagnostics use `~/Library/Logs/RoninStudio-WebSocket.log`.

Send `/pan` or `/tilt` with one numeric OSC argument, or `/panTilt` with two numeric arguments to set both axes together. Values are clamped to `[-1.00, 1.00]` and rounded to two decimal places. Each command with one axis sets the omitted axis to zero. Send updates around 10 Hz while moving; motion stops after 600 ms without updates. The global maximum pan/tilt command strengths in Preferences apply to both protocols. OSC does not provide authentication, so use it only on a trusted network. See [`docs/osc-control.md`](docs/osc-control.md) for the packet format and details.

