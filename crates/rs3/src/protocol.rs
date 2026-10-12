//! DUML frame encoding, as spoken by DJI RS-series gimbals over Bluetooth LE.
//!
//! Confirmed byte for byte against live captures from a DJI RS3:
//!
//! ```text
//! [0]     SOF 0x55
//! [1..3]  u16 LE: length in bits 0..9, version in bits 10..15
//! [3]     CRC8 over bytes [0..3]
//! [4]     source      (bits 0..4 device type, bits 5..7 index)
//! [5]     target      (same encoding)
//! [6..8]  u16 LE sequence number
//! [8]     cmd_type    (low nibble = ack type; 3 = reply required)
//! [9]     CmdSet
//! [10]    CmdID
//! [11..]  payload
//! [..]    CRC16 over everything preceding
//! ```

use crate::crc::{crc8, crc16};

pub const SOF: u8 = 0x55;
/// Overhead in bytes: 11-byte header plus the 2-byte trailing CRC16.
pub const OVERHEAD: usize = 13;
/// Live frames carry version 1; version 0 frames are not accepted.
pub const VERSION: u8 = 1;

/// The app's own DUML address. Every frame the gimbal emits is sent here.
pub const DEV_APP: u8 = 0x02;
/// The gimbal. The only node that answered a probe of all 32 device types.
pub const DEV_GIMBAL: u8 = 0x04;

pub mod cmd_set {
    pub const COMMON: u8 = 0x00;
    pub const CAMERA: u8 = 0x02;
    pub const GIMBAL: u8 = 0x04;
    pub const WIFI: u8 = 0x07;
    pub const BATTERY: u8 = 0x0D;
}

pub mod cmd_id {
    /// The only query this firmware answers.
    pub const COMMON_GET_VERSION: u8 = 0x01;
    pub const GIMBAL_SET_ATTI: u8 = 0x01;
    pub const GIMBAL_GET_ATTI: u8 = 0x02;
    pub const GIMBAL_CONTROL_ANGLE: u8 = 0x0A;
    pub const GIMBAL_CONTROL_SPEED: u8 = 0x0C;
    pub const GIMBAL_PUSH_MODEL_TYPE: u8 = 0x1C;
    pub const GIMBAL_PUSH_LOCK_STATUS: u8 = 0x27;
    pub const GIMBAL_RESET_AND_SET_MODE: u8 = 0x4C;
}

/// Frames the gimbal emits unprompted. Not replies to anything we sent.
pub const PUSH_FRAMES: &[(u8, u8)] = &[
    (0x00, 0x42),
    (0x00, 0xF1),
    (0x04, 0x1C),
    (0x04, 0x27),
    (0x0D, 0x02),
    (0x02, 0x80),
    (0x1C, 0x01),
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub source: u8,
    pub target: u8,
    pub seq: u16,
    pub cmd_type: u8,
    pub cmd_set: u8,
    pub cmd_id: u8,
    pub payload: Vec<u8>,
    pub version: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FrameError {
    #[error("frame too short: {0} bytes")]
    TooShort(usize),
    #[error("bad start-of-frame byte {0:#04x}")]
    BadSof(u8),
    #[error("length field says {declared} but got {actual} bytes")]
    LengthMismatch { declared: usize, actual: usize },
    #[error("header CRC8 mismatch")]
    HeaderCrc,
    #[error("frame CRC16 mismatch")]
    FrameCrc,
    #[error("payload too long: {0} bytes")]
    PayloadTooLong(usize),
}

impl Frame {
    /// A command addressed from the app to the gimbal.
    pub fn command(cmd_set: u8, cmd_id: u8, payload: Vec<u8>, seq: u16, want_reply: bool) -> Self {
        Self {
            source: DEV_APP,
            target: DEV_GIMBAL,
            seq,
            cmd_type: if want_reply { 0x03 } else { 0x00 },
            cmd_set,
            cmd_id,
            payload,
            version: VERSION,
        }
    }

    /// True when this frame is a reply rather than a command (bit 7 of cmd_type).
    pub fn is_reply(&self) -> bool {
        self.cmd_type & 0x80 != 0
    }

    /// True when this is one of the gimbal's unprompted status pushes.
    pub fn is_push(&self) -> bool {
        !self.is_reply() && PUSH_FRAMES.contains(&(self.cmd_set, self.cmd_id))
    }

    pub fn encode(&self) -> Result<Vec<u8>, FrameError> {
        let total = OVERHEAD + self.payload.len();
        if total > 0x3FF {
            return Err(FrameError::PayloadTooLong(self.payload.len()));
        }
        let ver_len = ((u16::from(self.version) & 0x3F) << 10) | total as u16;

        let mut out = Vec::with_capacity(total);
        out.push(SOF);
        out.extend_from_slice(&ver_len.to_le_bytes());
        out.push(crc8(&out));
        out.push(self.source);
        out.push(self.target);
        out.extend_from_slice(&self.seq.to_le_bytes());
        out.push(self.cmd_type);
        out.push(self.cmd_set);
        out.push(self.cmd_id);
        out.extend_from_slice(&self.payload);
        out.extend_from_slice(&crc16(&out).to_le_bytes());
        Ok(out)
    }

    pub fn decode(raw: &[u8]) -> Result<Self, FrameError> {
        if raw.len() < OVERHEAD {
            return Err(FrameError::TooShort(raw.len()));
        }
        if raw[0] != SOF {
            return Err(FrameError::BadSof(raw[0]));
        }
        let ver_len = u16::from_le_bytes([raw[1], raw[2]]);
        let declared = (ver_len & 0x3FF) as usize;
        if declared != raw.len() {
            return Err(FrameError::LengthMismatch {
                declared,
                actual: raw.len(),
            });
        }
        if crc8(&raw[..3]) != raw[3] {
            return Err(FrameError::HeaderCrc);
        }
        let want = u16::from_le_bytes([raw[raw.len() - 2], raw[raw.len() - 1]]);
        if crc16(&raw[..raw.len() - 2]) != want {
            return Err(FrameError::FrameCrc);
        }
        Ok(Self {
            source: raw[4],
            target: raw[5],
            seq: u16::from_le_bytes([raw[6], raw[7]]),
            cmd_type: raw[8],
            cmd_set: raw[9],
            cmd_id: raw[10],
            payload: raw[11..raw.len() - 2].to_vec(),
            version: ((ver_len >> 10) & 0x3F) as u8,
        })
    }
}

/// Split one BLE notification into the frames it contains.
///
/// A single notification routinely carries several frames packed back to back
/// (observed: 26+81=107, 41+14+18=73, 26+34+81=141), so the length field is
/// what delimits them, not the notification boundary.
pub fn split_frames(buf: &[u8]) -> Vec<Result<Frame, FrameError>> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < buf.len() {
        if buf[i] != SOF {
            match buf[i + 1..].iter().position(|&b| b == SOF) {
                Some(off) => {
                    i += off + 1;
                    continue;
                }
                None => break,
            }
        }
        if i + 3 > buf.len() {
            break;
        }
        let total = (u16::from_le_bytes([buf[i + 1], buf[i + 2]]) & 0x3FF) as usize;
        if total < OVERHEAD || i + total > buf.len() {
            break;
        }
        out.push(Frame::decode(&buf[i..i + total]));
        i += total;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_util::unhex;

    #[test]
    fn round_trips() {
        let f = Frame::command(cmd_set::GIMBAL, cmd_id::GIMBAL_CONTROL_SPEED, vec![1, 2, 3], 0xAB, true);
        let encoded = f.encode().unwrap();
        assert_eq!(Frame::decode(&encoded).unwrap(), f);
    }

    /// The exact frame that moved a real RS3.
    #[test]
    fn reproduces_the_frame_that_moved_the_gimbal() {
        let mut body = Vec::new();
        body.extend_from_slice(&200i16.to_le_bytes());
        body.extend_from_slice(&0i16.to_le_bytes());
        body.extend_from_slice(&0i16.to_le_bytes());
        body.push(0x80);
        let f = Frame::command(cmd_set::GIMBAL, cmd_id::GIMBAL_CONTROL_SPEED, body, 0x400, true);
        assert_eq!(
            hex(&f.encode().unwrap()),
            "5514046d0204000403040cc80000000000808794"
        );
    }

    /// Notifications captured from a real DJI RS3. Built from counted parts
    /// (11-byte header + payload + 2-byte CRC16) so the arithmetic is explicit.
    fn captured_frames() -> (String, String, String, String, String) {
        let zeros = |n: usize| "00".repeat(n);
        (
            // 26 bytes: ThirdPartyCamera push
            format!("551a04b104020000001c01{}005b10", "0301000100020001ff030001"),
            // 81 bytes: camera push, 68-byte payload
            format!("55510409e502bb42000280{}537c", zeros(68)),
            // 41 bytes: CommonPushStatus, 28-byte payload
            format!("552904c904026b0d0000f110c005{}9828", zeros(25)),
            // 14 bytes: GimbalPushModelType
            "550e046604026b0d00041c3d3713".to_string(),
            // 18 bytes: GimbalPushLockStatus
            "551204c704026b0d0004270000000000f29e".to_string(),
        )
    }

    #[test]
    fn splits_multi_frame_notifications() {
        let (f26, f81, f41, f14, f18) = captured_frames();

        // 107-byte notification = 26 + 81
        let frames = split_frames(&unhex(&format!("{f26}{f81}")));
        assert_eq!(frames.len(), 2);
        assert!(frames.iter().all(|f| f.is_ok()), "{frames:?}");
        let lens: Vec<usize> = frames
            .iter()
            .map(|f| f.as_ref().unwrap().payload.len() + OVERHEAD)
            .collect();
        assert_eq!(lens, vec![26, 81]);

        // 73-byte notification = 41 + 14 + 18
        let frames = split_frames(&unhex(&format!("{f41}{f14}{f18}")));
        assert_eq!(frames.len(), 3);
        assert!(frames.iter().all(|f| f.is_ok()), "{frames:?}");
        let lens: Vec<usize> = frames
            .iter()
            .map(|f| f.as_ref().unwrap().payload.len() + OVERHEAD)
            .collect();
        assert_eq!(lens, vec![41, 14, 18]);
    }

    #[test]
    fn single_frame_identifies_as_a_push() {
        let (f26, ..) = captured_frames();
        let f = Frame::decode(&unhex(&f26)).unwrap();
        assert_eq!((f.source, f.target), (0x04, DEV_APP));
        assert_eq!(f.version, VERSION);
        assert!(f.is_push());
        assert!(!f.is_reply());
    }

    #[test]
    fn rejects_a_corrupted_frame() {
        let (f26, ..) = captured_frames();
        let mut raw = unhex(&f26);
        raw[12] ^= 0xFF; // flip a payload bit; CRC16 must catch it
        assert_eq!(Frame::decode(&raw), Err(FrameError::FrameCrc));
    }

    #[test]
    fn decodes_the_version_reply_from_hardware() {
        // Reply to CommonGetVersion from a DJI RS3.
        let payload = unhex("000147423532000000000000000000000000020009074019020001000000");
        assert_eq!(payload[0], 0x00, "return code should be success");
        let hw = String::from_utf8_lossy(&payload[2..18])
            .trim_end_matches('\0')
            .to_string();
        assert_eq!(hw, "GB52");
    }

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }
}
