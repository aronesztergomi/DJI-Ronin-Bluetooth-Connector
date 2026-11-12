# WebSocket bridge requirements

## Scope

The macOS host can accept WebSocket text frames and translate normalized pan/tilt input into the existing gimbal speed-control path. This is a velocity control bridge, not an absolute positioning API.

## Preferences

- WebSocket listener is disabled by default and listens on port `81` when enabled; the user may select another valid TCP port (1–65535).
- Token authentication is configurable. It is required by default; when enabled, Preferences displays the per-install token and each connection must authenticate. It may be disabled for trusted networks, in which case any client that can reach the listener can control the gimbal.
- Preferences exposes independent maximum pan and tilt command strengths, each from `0%` to `100%` (default `100%`). Each axis is capped independently while preserving the command sign.
- Preferences exposes an optional WebSocket diagnostics logging toggle. When enabled, listener, connection, authentication, command parsing, and send/receive errors are recorded in `~/Library/Logs/RoninStudio.log`.
- Listener status and bind errors are visible in Preferences.

## Message protocol

- When token authentication is enabled, the first text frame on each connection must be `auth:<token>`; the server responds `ready` after successful authentication.
- When authentication is disabled, send motion commands immediately; no auth frame is expected.
- A motion frame contains one or two fields: `pan:X`, `tilt:Y`, or both, such as `pan:0.6 tilt:-0.2`. Fields may be separated by whitespace or a comma. Duplicate or unknown fields are invalid.
- Values are finite numbers normalized to `[-1, 1]`; values outside that interval are clamped. Positive pan is right; positive tilt is up. An omitted axis is commanded as zero for that frame; it does not retain its previous speed. Preferences limits further cap each axis magnitude.
- Valid motion frames receive `ok`. Invalid or oversized frames are rejected without generating motion. A connection that stops sending updates is stopped automatically after 600 ms; send updates at about 10 Hz for continuous movement.
- When authentication is enabled, it is checked per connection. Clients receive a short text response (`ready`, `ok`, or an error response).

## Safety and networking

The listener accepts connections on the Mac's network interfaces. Disabling token authentication means any reachable client can control the gimbal. Do not expose the listener directly to the public Internet without authentication and network-level protections; use a trusted VPN or authenticated tunnel. The limits cap command speed only. They are not angular/travel boundaries: the gimbal does not provide position feedback needed to guarantee physical pan/tilt stops.

## Examples

With authentication enabled:

```text
auth:<token>
pan:0.6
tilt:0.9
pan:0.4 tilt:-0.2
pan:0 tilt:0
```

With authentication disabled, omit the auth frame:

```text
pan:0.6
tilt:0.9
pan:0.4 tilt:-0.2
pan:0 tilt:0
```

A pan-only frame commands zero tilt, and a tilt-only frame commands zero pan. A client should resend the desired command periodically while movement is intended. Stopping updates causes the bridge to send a stop command after the timeout.
