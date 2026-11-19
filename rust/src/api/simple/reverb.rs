#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReverbAlgorithm {
    /// Jezar Freeverb (Concert Hall preset)
    Freeverb,
    /// FunDSP 32-channel FDN stereo reverb (`reverb_stereo`)
    FundspStereo,
}

impl ReverbAlgorithm {
    pub fn from_i32(value: i32) -> Self {
        match value {
            1 => Self::FundspStereo,
            _ => Self::Freeverb,
        }
    }

    pub fn as_i32(self) -> i32 {
        match self {
            Self::Freeverb => 0,
            Self::FundspStereo => 1,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ReverbConfig {
    pub enabled: bool,
    pub algorithm: ReverbAlgorithm,
    /// Dry signal mix (0.0..=2.0). Default: 0.90
    pub dry_mix: f32,
    /// Wet reverb mix (0.0..=2.0). Default: 0.22
    pub wet_mix: f32,
    /// Normalized room size (0.0..=1.0). Default: 0.70
    pub room_size: f32,
    /// High-frequency damping (0.0..=1.0). Default: 0.50
    pub damping: f32,
    /// Stereo width for Freeverb (0.0..=1.0). Default: 0.85
    pub width: f32,
    /// Reverberation time RT60 in seconds for FunDSP (0.3..=10.0). Default: 3.02
    pub time_seconds: f32,
    /// Freeze mode for Freeverb
    pub freeze: bool,
}

impl Default for ReverbConfig {
    /// Defaults to the Freeverb Concert Hall preset.
    fn default() -> Self {
        Self::freeverb_default()
    }
}

impl ReverbConfig {
    /// Default parameters for Freeverb.
    pub fn freeverb_default() -> Self {
        Self {
            enabled: false,
            algorithm: ReverbAlgorithm::Freeverb,
            dry_mix: 0.90,
            wet_mix: 0.22,
            room_size: 0.70,
            damping: 0.50,
            width: 0.85,
            time_seconds: 3.02,
            freeze: false,
        }
    }

    /// Default parameters for FunDSP 32-ch FDN Stereo Reverb.
    pub fn fundsp_fdn_default() -> Self {
        Self {
            enabled: false,
            algorithm: ReverbAlgorithm::FundspStereo,
            dry_mix: 0.76,
            wet_mix: 1.00,
            room_size: 0.88,
            damping: 1.00,
            width: 0.85,
            time_seconds: 3.02,
            freeze: false,
        }
    }

    pub fn sanitized(mut self) -> Self {
        self.dry_mix = self.dry_mix.clamp(0.0, 2.0);
        self.wet_mix = self.wet_mix.clamp(0.0, 2.0);
        self.room_size = self.room_size.clamp(0.0, 1.0);
        self.damping = self.damping.clamp(0.0, 1.0);
        self.width = self.width.clamp(0.0, 1.0);
        self.time_seconds = self.time_seconds.clamp(0.3, 10.0);
        self
    }
}
