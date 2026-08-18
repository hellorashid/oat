pub const TARGET_SAMPLE_RATE: u32 = 16_000;

pub fn downmix_interleaved(input: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return input.to_vec();
    }
    input
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / channels as f32)
        .collect()
}

#[allow(dead_code)]
pub fn bytes_to_f32_le(bytes: &[u8], bytes_per_sample: usize) -> Vec<f32> {
    match bytes_per_sample {
        2 => bytes
            .chunks_exact(2)
            .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]) as f32 / 32768.0)
            .collect(),
        4 => bytes
            .chunks_exact(4)
            .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
            .collect(),
        _ => Vec::new(),
    }
}

pub fn sample_to_f32<T: ToF32>(sample: T) -> f32 {
    sample.to_f32()
}

pub trait ToF32 {
    fn to_f32(self) -> f32;
}

impl ToF32 for f32 {
    fn to_f32(self) -> f32 {
        self
    }
}

impl ToF32 for i16 {
    fn to_f32(self) -> f32 {
        self as f32 / 32768.0
    }
}

impl ToF32 for i32 {
    fn to_f32(self) -> f32 {
        self as f32 / 2147483648.0
    }
}

impl ToF32 for u16 {
    fn to_f32(self) -> f32 {
        (self as f32 - 32768.0) / 32768.0
    }
}

/// Linear resampler that keeps fractional position across chunks.
pub struct LinearResampler {
    step: f64,
    pos: f64,
    last: f32,
    primed: bool,
}

impl LinearResampler {
    pub fn new(from: u32, to: u32) -> Self {
        let from = from.max(1) as f64;
        let to = to.max(1) as f64;
        Self {
            step: from / to,
            pos: 0.0,
            last: 0.0,
            primed: false,
        }
    }

    pub fn push(&mut self, input: &[f32]) -> Vec<f32> {
        if input.is_empty() {
            return Vec::new();
        }
        if (self.step - 1.0).abs() < f64::EPSILON {
            return input.to_vec();
        }

        let mut output = Vec::new();
        let mut index = 0usize;

        if !self.primed {
            self.last = input[0];
            self.primed = true;
            index = 1;
            if input.len() == 1 {
                return Vec::new();
            }
        }

        while self.pos < 1.0 {
            let next = input.get(index).copied().unwrap_or(self.last);
            let t = self.pos as f32;
            output.push(self.last * (1.0 - t) + next * t);
            self.pos += self.step;
        }

        while index < input.len() {
            while self.pos >= 1.0 {
                self.last = input[index];
                index += 1;
                self.pos -= 1.0;
                if index >= input.len() {
                    return output;
                }
            }
            let next = input[index];
            let t = self.pos as f32;
            output.push(self.last * (1.0 - t) + next * t);
            self.pos += self.step;
        }

        output
    }
}

pub fn convert_chunk<T: ToF32 + Copy>(
    data: &[T],
    channels: usize,
    resampler: &mut LinearResampler,
) -> Vec<f32> {
    let floats: Vec<f32> = data.iter().copied().map(sample_to_f32).collect();
    let mono = downmix_interleaved(&floats, channels.max(1));
    resampler.push(&mono)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downmix_averages_channels() {
        let mono = downmix_interleaved(&[1.0, -1.0, 0.5, 0.5], 2);
        assert_eq!(mono, vec![0.0, 0.5]);
    }

    #[test]
    fn identity_resample_passthrough() {
        let mut resampler = LinearResampler::new(16_000, 16_000);
        assert_eq!(resampler.push(&[0.1, 0.2, 0.3]), vec![0.1, 0.2, 0.3]);
    }

    #[test]
    fn downsample_halves_length() {
        let mut resampler = LinearResampler::new(32_000, 16_000);
        let input: Vec<f32> = (0..32).map(|i| i as f32).collect();
        let output = resampler.push(&input);
        assert!((15..=17).contains(&output.len()), "len was {}", output.len());
    }

    #[test]
    fn bytes_i16_roundtrip_scale() {
        let bytes = 16384i16.to_le_bytes();
        let samples = bytes_to_f32_le(&bytes, 2);
        assert!((samples[0] - 0.5).abs() < 0.01);
    }
}
