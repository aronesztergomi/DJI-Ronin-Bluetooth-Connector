# WebSocket bridge requirements

## Scope

The macOS host can accept WebSocket text frames and translate normalized pan/tilt input into the existing gimbal speed-control path. This is a velocity control bridge, not an absolute positioning API.

## Preferences

- WebSocket listener is disabled by default and listens on port `81` when enabled; the user may select another valid TCP port (1–65535).
- Preferences exposes independent maximum pan and tilt command strengths, each from `0%` to `100%` (default `100%`). Each axis is capped independently while preserving the command sign.
- Preferences displays the per-install access token used to authenticate clients.
- Listener status and bind errors are visible in Preferences.

## Message protocol

- The first text frame on each connection must be `auth:<token>`.
- After authentication, each motion frame contains exactly two fields, `pan:X tilt:Y`, with either field order accepted. Commas may separate the fields instead of whitespace.
- `X` and `Y` are finite numbers, normalized to `[-1, 1]`; values outside that interval are clamped. Positive pan is right; positive tilt is up. The Preferences limits further cap each axis magnitude.
- Invalid or oversized frames are rejected without generating motion. A connection that stops sending updates is stopped automatically after 600 ms; send updates at about 10 Hz for continuous movement. Sending `pan:0 tilt:0` stops immediately.
- Authentication is per connection. Clients receive a short text response (`ready`, `ok`, or an error response).

## Safety and networking

The listener accepts connections on the Mac's network interfaces. Do not expose it directly to the public Internet without network-level protections; use a trusted VPN or authenticated tunnel and keep the access token private. The limits cap command speed only. They are not angular/travel boundaries: the gimbal does not provide position feedback needed to guarantee physical pan/tilt stops.

## Examples

```text
auth:<token>
pan:0.5 tilt:-0.25
pan:0 tilt:0
```

A client should send motion updates periodically while movement is intended. Stopping updates causes the bridge to send a stop command after the timeout.
