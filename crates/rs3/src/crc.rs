//! DUML checksums.
//!
//! Two reflected, table-driven checksums cover every frame: a CRC-8 over the
//! four-byte header and a CRC-16 over everything before the trailing two
//! bytes.
//!
//! The seeds are the part worth getting right — `0x77` and `0x3692`, neither
//! of them the usual value for its polynomial. A frame carrying the wrong
//! checksum is dropped in silence rather than refused, so the failure looks
//! like a dead link rather than a bad frame.

/// Reversed polynomial `0x8C` == bit-reverse of `0x31` (CRC-8, reflected).
const CRC8_POLY_REV: u8 = 0x8C;
/// Reversed polynomial `0x8408` == bit-reverse of `0x1021` (CRC-16/CCITT).
const CRC16_POLY_REV: u16 = 0x8408;

pub const CRC8_SEED: u8 = 0x77;
pub const CRC16_SEED: u16 = 0x3692;

const CRC8_TABLE: [u8; 256] = build_crc8_table();
const CRC16_TABLE: [u16; 256] = build_crc16_table();

const fn build_crc8_table() -> [u8; 256] {
    let mut table = [0u8; 256];
    let mut i = 0usize;
    while i < 256 {
        let mut reg = i as u8;
        let mut bit = 0;
        while bit < 8 {
            reg = if reg & 1 != 0 {
                (reg >> 1) ^ CRC8_POLY_REV
            } else {
                reg >> 1
            };
            bit += 1;
        }
        table[i] = reg;
        i += 1;
    }
    table
}

const fn build_crc16_table() -> [u16; 256] {
    let mut table = [0u16; 256];
    let mut i = 0usize;
    while i < 256 {
        let mut reg = i as u16;
        let mut bit = 0;
        while bit < 8 {
            reg = if reg & 1 != 0 {
                (reg >> 1) ^ CRC16_POLY_REV
            } else {
                reg >> 1
            };
            bit += 1;
        }
        table[i] = reg;
        i += 1;
    }
    table
}

/// Header check over the first three bytes of a frame.
///
/// Mirrors the routine at `0x100b81264`: `crc = table[crc ^ byte]`.
pub fn crc8(data: &[u8]) -> u8 {
    data.iter()
        .fold(CRC8_SEED, |crc, &b| CRC8_TABLE[(crc ^ b) as usize])
}

/// Frame check over everything preceding the trailing two bytes.
///
/// Mirrors the routine at `0x100b812cc`:
/// `crc = (crc >> 8) ^ table[(crc ^ byte) & 0xff]`.
pub fn crc16(data: &[u8]) -> u16 {
    data.iter().fold(CRC16_SEED, |crc, &b| {
        (crc >> 8) ^ CRC16_TABLE[((crc ^ u16::from(b)) & 0xFF) as usize]
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Frames captured from a real DJI RS3 over `fff4`. If the tables or seeds
    /// were wrong these would not validate.
    const CAPTURED: &[&str] = &[
        "551a04b104020000001c010301000100020001ff030001005b10",
        "5528040de5026a0d000042010000000000000000000000000000000000000000000000000000506b",
        "552204eae502981d000d02000020000023060000400a0000f10900008d010461c2f3",
    ];

    #[test]
    fn validates_frames_from_real_hardware() {
        for hex in CAPTURED {
            let raw = crate::test_util::unhex(hex);
            assert_eq!(crc8(&raw[..3]), raw[3], "header CRC8 for {hex}");
            let want = u16::from_le_bytes([raw[raw.len() - 2], raw[raw.len() - 1]]);
            assert_eq!(crc16(&raw[..raw.len() - 2]), want, "frame CRC16 for {hex}");
        }
    }

    #[test]
    fn seeds_match_the_binary() {
        assert_eq!(CRC8_SEED, 0x77);
        assert_eq!(CRC16_SEED, 0x3692);
    }
}
