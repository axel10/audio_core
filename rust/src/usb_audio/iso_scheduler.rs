//! Fractional & explicit-feedback isochronous packet scheduler.
//! Adapted from Flick's `IsoPacketScheduler` (MIT License).

#[derive(Debug, Clone)]
pub(crate) struct IsoPacketScheduler {
    sample_rate: u32,
    service_interval_us: u32,
    nominal_remainder: u64,
    bytes_per_frame: usize,
    packets_per_transfer: usize,
    feedback_frames_per_packet: Option<f64>,
    feedback_remainder: f64,
}

impl IsoPacketScheduler {
    pub(crate) fn new(sample_rate: u32, bytes_per_frame: usize, service_interval_us: u32) -> Self {
        let interval = service_interval_us.max(125);
        let packets_per_transfer = if interval >= 1_000 {
            16usize
        } else {
            (4_000u32 / interval).clamp(16, 32) as usize
        };

        Self {
            sample_rate,
            service_interval_us: interval,
            nominal_remainder: 0,
            bytes_per_frame,
            packets_per_transfer,
            feedback_frames_per_packet: None,
            feedback_remainder: 0.0,
        }
    }

    pub(crate) fn packets_per_transfer(&self) -> usize {
        self.packets_per_transfer
    }

    pub(crate) fn next_transfer_packet_bytes(&mut self) -> Vec<usize> {
        (0..self.packets_per_transfer)
            .map(|_| self.next_packet_bytes())
            .collect()
    }

    /// Update packet timing from a device explicit-feedback report.
    /// Accepts values within ±2% of nominal sample rate.
    pub(crate) fn update_feedback_frames_per_packet(&mut self, frames_per_packet: f64) -> bool {
        if !frames_per_packet.is_finite() || frames_per_packet <= 0.0 {
            return false;
        }

        let nominal = self.nominal_frames_per_packet().max(0.001);
        if frames_per_packet < nominal * 0.98 || frames_per_packet > nominal * 1.02 {
            return false;
        }

        self.feedback_frames_per_packet = Some(match self.feedback_frames_per_packet {
            Some(prev) => prev * 0.8 + frames_per_packet * 0.2,
            None => frames_per_packet,
        });
        true
    }

    fn nominal_frames_per_packet(&self) -> f64 {
        self.sample_rate as f64 * self.service_interval_us as f64 / 1_000_000.0
    }

    fn next_packet_bytes(&mut self) -> usize {
        let frames = if let Some(feedback) = self.feedback_frames_per_packet {
            self.feedback_remainder += feedback;
            let frames = self.feedback_remainder.floor() as usize;
            self.feedback_remainder -= frames as f64;
            frames
        } else {
            let total = self.nominal_remainder
                + (self.sample_rate as u64 * self.service_interval_us as u64);
            let frames = (total / 1_000_000) as usize;
            self.nominal_remainder = total % 1_000_000;
            frames
        };
        frames.saturating_mul(self.bytes_per_frame)
    }
}
