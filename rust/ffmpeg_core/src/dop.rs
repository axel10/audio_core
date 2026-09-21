//! DoP (DSD over PCM Frames) v1.1 standard encoder and conversion utilities.
//!
//! Standard DoP v1.1 specifies for DSD64:
//! - 176.4 kHz sampling rate
//! - 16 DSD bits per channel per frame
//! - 24-bit PCM container word:
//!   - bits 23..16: 8-bit DSD marker (0x05 on even frames, 0xFA on odd frames)
//!   - bits 15..0: 16 DSD bits (MSB first)

pub const DOP_MARKER_EVEN: u8 = 0x05;
pub const DOP_MARKER_ODD: u8 = 0xFA;
pub const DOP_DSD64_SAMPLE_RATE: u32 = 176_400;

#[derive(Debug, Clone)]
pub struct DopEncoder {
    marker_phase: bool,
}

impl Default for DopEncoder {
    fn default() -> Self {
        Self::new()
    }
}

impl DopEncoder {
    pub fn new() -> Self {
        Self { marker_phase: false }
    }

    pub fn reset(&mut self) {
        self.marker_phase = false;
    }

    /// Generates the next alternating DoP marker (0x05 for even, 0xFA for odd).
    #[inline]
    pub fn next_marker(&mut self) -> u8 {
        let marker = if self.marker_phase {
            DOP_MARKER_ODD
        } else {
            DOP_MARKER_EVEN
        };
        self.marker_phase = !self.marker_phase;
        marker
    }

    /// Encodes a stereo frame of 16-bit DSD samples (MSB first) into two 24-bit unsigned words.
    #[inline]
    pub fn encode_stereo_u24(&mut self, left_dsd: u16, right_dsd: u16) -> (u32, u32) {
        let marker = self.next_marker() as u32;
        let left_u24 = (marker << 16) | (left_dsd as u32);
        let right_u24 = (marker << 16) | (right_dsd as u32);
        (left_u24, right_u24)
    }

    /// Encodes a stereo frame of 16-bit DSD samples into bit-exact f32 PCM samples.
    #[inline]
    pub fn encode_stereo_f32(&mut self, left_dsd: u16, right_dsd: u16) -> (f32, f32) {
        let (left_u24, right_u24) = self.encode_stereo_u24(left_dsd, right_dsd);
        (dop_u24_to_f32(left_u24), dop_u24_to_f32(right_u24))
    }
}

/// Converts a 24-bit unsigned DoP word (where bits 23..16 are marker and 15..0 are DSD data)
/// into a signed 24-bit integer, and normalizes it to f32 by dividing by 2^23 (8,388,608.0).
///
/// Because 8,388,608 is an exact power of 2, this division only changes the IEEE-754 exponent
/// and leaves all 24 bits of mantissa/sign 100% bit-exact without floating point rounding error.
#[inline]
pub fn dop_u24_to_f32(val24: u32) -> f32 {
    let signed_val: i32 = if (val24 & 0x800000) != 0 {
        (val24 | 0xFF000000) as i32
    } else {
        (val24 & 0x007FFFFF) as i32
    };
    signed_val as f32 / 8_388_608.0
}

/// Reconstructs the 24-bit unsigned DoP word from the f32 PCM sample.
/// Multiplying by 8,388,608.0 exactly inverts the power-of-2 division.
#[inline]
pub fn f32_to_dop_u24(sample: f32) -> u32 {
    let scaled = (sample * 8_388_608.0).round().clamp(-8_388_608.0, 8_388_607.0) as i32;
    (scaled as u32) & 0x00FFFFFF
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dop_encoder_alternates_markers() {
        let mut enc = DopEncoder::new();
        assert_eq!(enc.next_marker(), DOP_MARKER_EVEN);
        assert_eq!(enc.next_marker(), DOP_MARKER_ODD);
        assert_eq!(enc.next_marker(), DOP_MARKER_EVEN);
        assert_eq!(enc.next_marker(), DOP_MARKER_ODD);
    }

    #[test]
    fn test_dop_f32_roundtrip_bit_exact() {
        let mut enc = DopEncoder::new();
        let mut expected_enc = DopEncoder::new();
        // Test corner cases: silence, alternating bits, random payload
        let test_dsd_pairs = [
            (0x0000, 0x0000),
            (0xFFFF, 0xFFFF),
            (0xAAAA, 0x5555),
            (0x1234, 0xABCD),
            (0x6969, 0x9696),
        ];

        for &(left_dsd, right_dsd) in &test_dsd_pairs {
            let (expected_l, expected_r) = expected_enc.encode_stereo_u24(left_dsd, right_dsd);
            let (f32_l, f32_r) = enc.encode_stereo_f32(left_dsd, right_dsd);

            let reconstructed_l = f32_to_dop_u24(f32_l);
            let reconstructed_r = f32_to_dop_u24(f32_r);

            assert_eq!(reconstructed_l, expected_l);
            assert_eq!(reconstructed_r, expected_r);
            // Verify marker
            let marker_l = (reconstructed_l >> 16) as u8;
            assert!(marker_l == DOP_MARKER_EVEN || marker_l == DOP_MARKER_ODD);
            // Verify payload
            assert_eq!((reconstructed_l & 0xFFFF) as u16, left_dsd);
            assert_eq!((reconstructed_r & 0xFFFF) as u16, right_dsd);
        }
    }
}
