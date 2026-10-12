//! Control a DJI RS-series gimbal over Bluetooth LE.
//!
//! No DJI app, no APC-R hardware, no CAN adapter: this speaks the gimbal's own
//! BLE protocol directly, and is verified against a physical DJI RS3
//! (hardware id `GB52`, firmware 7.9.0.2).
//!
//! ```no_run
//! use rs3::{Direction, Gimbal, Position};
//!
//! # async fn demo() -> rs3::Result<()> {
//! let gimbal = Gimbal::connect_first().await?;
//! println!("{}", gimbal.version().await?);
//!
//! // Hold a direction for a while, then stop.
//! gimbal.nudge(Direction::Left, 400, std::time::Duration::from_secs(1)).await?;
//!
//! // Remember where we are, go elsewhere, come back.
//! let home = Position::new(0, 0, 0);
//! gimbal.goto(home).await?;
//! # Ok(()) }
//! ```
//!
//! # A note on how this gimbal behaves
//!
//! The RS3's BLE firmware is **push-oriented, not request/response**. It
//! answers exactly one query (`CommonGetVersion`) and streams state unprompted;
//! everything else is silent. Control commands are fire-and-forget and send no
//! reply, so a silent command is a *normal* command, not a failed one.

pub mod crc;
pub mod presets;
pub mod protocol;

mod ble;

pub use ble::{DiscoveredGimbal, Gimbal, KeepAlive};
pub use presets::{Preset, PresetStore};
pub use protocol::{Frame, FrameError};

use std::time::Duration;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("bluetooth: {0}")]
    Bluetooth(#[from] btleplug::Error),
    #[error("no bluetooth adapter found")]
    NoAdapter,
    #[error("no RS-series gimbal found; is it powered on and not connected to the DJI app?")]
    NotFound,
    #[error("device has no fff0 service - not an RS gimbal")]
    NotAGimbal,
    #[error("gimbal is not connected")]
    NotConnected,
    #[error("timed out waiting for a reply")]
    Timeout,
    #[error("frame: {0}")]
    Frame(#[from] FrameError),
    #[error("unexpected reply payload ({0} bytes)")]
    BadReply(usize),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("presets: {0}")]
    Presets(String),
}

/// Which way to move. Maps onto the gimbal's yaw and pitch axes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
    RollLeft,
    RollRight,
}

impl Direction {
    /// Convert a direction plus a magnitude into a signed (yaw, roll, pitch)
    /// speed triplet.
    ///
    /// The 7-byte body is three little-endian `i16` axes followed by a
    /// control byte.
    pub fn to_speeds(self, speed: i16) -> Speeds {
        let s = speed.abs();
        match self {
            Direction::Left => Speeds { yaw: -s, roll: 0, pitch: 0 },
            Direction::Right => Speeds { yaw: s, roll: 0, pitch: 0 },
            Direction::Up => Speeds { yaw: 0, roll: 0, pitch: s },
            Direction::Down => Speeds { yaw: 0, roll: 0, pitch: -s },
            Direction::RollLeft => Speeds { yaw: 0, roll: -s, pitch: 0 },
            Direction::RollRight => Speeds { yaw: 0, roll: s, pitch: 0 },
        }
    }
}

/// A signed speed per axis. Units are the gimbal's own; larger is faster.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Speeds {
    pub yaw: i16,
    pub roll: i16,
    pub pitch: i16,
}

impl Speeds {
    pub const STOP: Speeds = Speeds { yaw: 0, roll: 0, pitch: 0 };

    pub fn new(yaw: i16, roll: i16, pitch: i16) -> Self {
        Self { yaw, roll, pitch }
    }

    /// The 7-byte `ControlGimbalSpeed` body.
    pub fn to_payload(self, ctrl: u8) -> Vec<u8> {
        let mut out = Vec::with_capacity(7);
        out.extend_from_slice(&self.yaw.to_le_bytes());
        out.extend_from_slice(&self.roll.to_le_bytes());
        out.extend_from_slice(&self.pitch.to_le_bytes());
        out.push(ctrl);
        out
    }
}

/// An absolute gimbal attitude, in tenths of a degree.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Position {
    pub yaw: i16,
    pub roll: i16,
    pub pitch: i16,
}

impl Position {
    pub fn new(yaw: i16, roll: i16, pitch: i16) -> Self {
        Self { yaw, roll, pitch }
    }

    pub fn from_degrees(yaw: f32, roll: f32, pitch: f32) -> Self {
        Self {
            yaw: (yaw * 10.0) as i16,
            roll: (roll * 10.0) as i16,
            pitch: (pitch * 10.0) as i16,
        }
    }

    pub fn degrees(self) -> (f32, f32, f32) {
        (
            f32::from(self.yaw) / 10.0,
            f32::from(self.roll) / 10.0,
            f32::from(self.pitch) / 10.0,
        )
    }

    /// The 9-byte `ControlGimbalAngle` body.
    ///
    /// Nine bytes: three `i16` axes plus three trailing bytes. The control
    /// byte and duration mirror the sibling CAN
    /// protocol's position command; this layout is **not yet confirmed on
    /// hardware**, unlike the speed command.
    pub fn to_payload(self, ctrl: u8, time_for_action: u8) -> Vec<u8> {
        let mut out = Vec::with_capacity(9);
        out.extend_from_slice(&self.yaw.to_le_bytes());
        out.extend_from_slice(&self.roll.to_le_bytes());
        out.extend_from_slice(&self.pitch.to_le_bytes());
        out.push(ctrl);
        out.push(time_for_action);
        out.push(0);
        out
    }
}

/// What `CommonGetVersion` reports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version {
    pub hardware: String,
    pub versions: Vec<String>,
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} ({})", self.hardware, self.versions.join(", "))
    }
}

impl Version {
    pub(crate) fn parse(payload: &[u8]) -> Result<Self> {
        if payload.len() < 30 {
            return Err(Error::BadReply(payload.len()));
        }
        let hardware = String::from_utf8_lossy(&payload[2..18])
            .trim_end_matches('\0')
            .to_string();
        let versions = [18usize, 22, 26]
            .iter()
            .map(|&o| {
                payload[o..o + 4]
                    .iter()
                    .rev()
                    .map(|b| b.to_string())
                    .collect::<Vec<_>>()
                    .join(".")
            })
            .collect();
        Ok(Self { hardware, versions })
    }
}

/// How often sustained-motion helpers resend the speed command.
pub const CONTROL_RATE: Duration = Duration::from_millis(100);
/// Control byte accepted by the gimbal for speed commands.
pub const CTRL_BYTE: u8 = 0x80;
/// Body of the recentre command: two bytes, `0xFE` then `0x01`.
/// See [`Gimbal::recenter`].
pub const RECENTER_BODY: [u8; 2] = [0xFE, 0x01];

#[cfg(test)]
pub(crate) mod test_util {
    pub fn unhex(s: &str) -> Vec<u8> {
        let cleaned: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
        assert!(
            cleaned.len().is_multiple_of(2),
            "hex vector has an odd digit count ({})",
            cleaned.len()
        );
        (0..cleaned.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&cleaned[i..i + 2], 16).unwrap())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directions_map_to_axes() {
        assert_eq!(Direction::Left.to_speeds(300).yaw, -300);
        assert_eq!(Direction::Right.to_speeds(300).yaw, 300);
        assert_eq!(Direction::Up.to_speeds(300).pitch, 300);
        assert_eq!(Direction::Down.to_speeds(300).pitch, -300);
        assert_eq!(Direction::Left.to_speeds(-300).yaw, -300, "magnitude only");
    }

    /// Two bytes, not one: a one-byte body is a different command as far as
    /// the gimbal is concerned, and is ignored.
    #[test]
    fn recenter_body_is_two_bytes() {
        assert_eq!(RECENTER_BODY.len(), 2);
        assert_eq!(RECENTER_BODY, [0xFE, 0x01]);
    }

    #[test]
    fn speed_payload_is_seven_bytes() {
        let p = Speeds::new(200, 0, 0).to_payload(CTRL_BYTE);
        assert_eq!(p.len(), 7);
        assert_eq!(p, vec![0xC8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80]);
    }

    #[test]
    fn angle_payload_is_nine_bytes() {
        assert_eq!(Position::new(900, 0, 0).to_payload(0x01, 20).len(), 9);
    }

    #[test]
    fn degrees_round_trip() {
        let p = Position::from_degrees(90.0, 0.0, -45.0);
        assert_eq!(p.yaw, 900);
        assert_eq!(p.pitch, -450);
        let (y, _, pi) = p.degrees();
        assert_eq!((y, pi), (90.0, -45.0));
    }

    #[test]
    fn parses_the_version_reply_from_hardware() {
        let payload =
            test_util::unhex("000147423532000000000000000000000000020009074019020001000000");
        let v = Version::parse(&payload).unwrap();
        assert_eq!(v.hardware, "GB52");
        assert_eq!(v.versions[0], "7.9.0.2");
    }
}
