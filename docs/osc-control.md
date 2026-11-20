# OSC control bridge

## Setup

Enable the OSC listener in Preferences. It is an independent UDP service, disabled by default with a port of `8000`. Configure its port and diagnostics logging. The listener binds to loopback by default; enable **Allow connections from remote hosts** only when remote control is needed, preferably with a VPN or tunnel. OSC has no authentication, so do not expose it directly to untrusted networks.

OSC diagnostics are written to `~/Library/Logs/RoninStudio-OSC.log`. The general application session log remains `~/Library/Logs/RoninStudio.log`.

## Message format

Send OSC messages with these exact addresses and arguments:

| Address | Arguments | Effect |
|---|---|---|
| `/pan` | one float32, float64, or int32 | Set pan; tilt is zero for this command |
| `/tilt` | one float32, float64, or int32 | Set tilt; pan is zero for this command |
| `/panTilt` | two float32, float64, or int32 arguments | Set pan and tilt together |

Each input is clamped to `[-1.00, 1.00]` and rounded to two decimal places. Positive pan is right and positive tilt is up. To continuously move, resend at roughly 10 Hz. Remote motion stops automatically after 600 ms without an update. A message received while no gimbal is connected is ignored and recorded in the OSC diagnostic log if logging is enabled.

The global maximum pan and tilt command strengths in Preferences apply to OSC. They limit speed command magnitude, not physical gimbal angle or travel. OSC does not authenticate messages; remote OSC should be carried over a trusted VPN or tunnel.

## Example

Send `/panTilt` with two float32 arguments `0.50` and `-0.25` to move right and down. To stop explicitly, send `/panTilt` with `0.00, 0.00`. Sending a single-axis message also sets the other axis to zero.

OSC datagrams are parsed as single OSC messages; OSC bundles and wildcard address patterns are not supported. The bridge tracks at most 32 active UDP endpoint connections and closes an idle connection after 2 seconds.
