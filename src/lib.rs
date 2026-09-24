use std::collections::{HashMap, HashSet};

const WIDTH: usize = 9;
const HEIGHT: usize = 8;
const PIXEL_BYTES: usize = WIDTH * HEIGHT * 4;
const MAX_DISTANCE: u32 = 7;
const NEARBY_DISTANCE: u32 = 10;
const NEARBY_SECONDS: i64 = 60 * 60;

/// RGBA pixels are supplied in row-major order, at 9 by 8 pixels.
/// The returned hash captures horizontal brightness changes.
#[no_mangle]
pub unsafe extern "C" fn image_signature(pixels: *const u8, len: usize, color: *mut u32) -> u64 {
    if pixels.is_null() || color.is_null() || len < PIXEL_BYTES {
        return 0;
    }
    let pixels = std::slice::from_raw_parts(pixels, PIXEL_BYTES);
    let mut brightness = [0u16; WIDTH * HEIGHT];
    let mut sums = [0u32; 3];
    for (index, rgba) in pixels.chunks_exact(4).enumerate() {
        brightness[index] = (rgba[0] as u16 * 30 + rgba[1] as u16 * 59 + rgba[2] as u16 * 11) / 100;
        for channel in 0..3 {
            sums[channel] += rgba[channel] as u32;
        }
    }

    let mut hash = 0u64;
    for y in 0..HEIGHT {
        for x in 0..WIDTH - 1 {
            hash <<= 1;
            hash |= u64::from(brightness[y * WIDTH + x] > brightness[y * WIDTH + x + 1]);
        }
    }
    *color = ((sums[0] / 72) << 16) | ((sums[1] / 72) << 8) | (sums[2] / 72);
    hash
}

struct DisjointSet {
    parents: Vec<usize>,
    sizes: Vec<usize>,
}

impl DisjointSet {
    fn new(count: usize) -> Self {
        Self { parents: (0..count).collect(), sizes: vec![1; count] }
    }

    fn root(&mut self, index: usize) -> usize {
        if self.parents[index] != index {
            self.parents[index] = self.root(self.parents[index]);
        }
        self.parents[index]
    }

    fn join(&mut self, a: usize, b: usize) {
        let mut a = self.root(a);
        let mut b = self.root(b);
        if a == b { return; }
        if self.sizes[a] < self.sizes[b] { std::mem::swap(&mut a, &mut b); }
        self.parents[b] = a;
        self.sizes[a] += self.sizes[b];
    }
}

fn color_close(a: u32, b: u32) -> bool {
    let channel = |value: u32, shift| ((value >> shift) & 255u32) as i32;
    let difference = [16, 8, 0]
        .into_iter()
        .map(|shift| (channel(a, shift) - channel(b, shift)).abs())
        .sum::<i32>();
    difference <= 75
}

fn group(hashes: &[u64], colors: &[u32], timestamps: &[i64]) -> (Vec<u32>, usize) {
    let count = hashes.len();
    assert_eq!(colors.len(), count);
    assert_eq!(timestamps.len(), count);
    let mut sets = DisjointSet::new(count);
    // With at most seven differing bits, at least one of eight byte-sized
    // partitions is identical. This finds every candidate within that radius.
    let mut index: HashMap<(u8, u8), Vec<usize>> = HashMap::new();
    for current in 0..count {
        let mut seen = HashSet::new();
        for part in 0..8u8 {
            let byte = ((hashes[current] >> (part * 8)) & 255) as u8;
            if let Some(candidates) = index.get(&(part, byte)) {
                for &other in candidates {
                    if seen.insert(other)
                        && (hashes[current] ^ hashes[other]).count_ones() <= MAX_DISTANCE
                        && color_close(colors[current], colors[other])
                    {
                        sets.join(current, other);
                    }
                }
            }
            index.entry((part, byte)).or_default().push(current);
        }
    }

    // Time is a bonus, not a requirement: photos taken within an hour can
    // differ a little more, while near-duplicates from any date still match.
    let mut dated: Vec<usize> = (0..count)
        .filter(|&item| timestamps[item] != i64::MIN)
        .collect();
    dated.sort_unstable_by_key(|&item| timestamps[item]);
    let mut window_start = 0;
    for end in 0..dated.len() {
        let current = dated[end];
        while timestamps[current].saturating_sub(timestamps[dated[window_start]]) > NEARBY_SECONDS {
            window_start += 1;
        }
        for &other in &dated[window_start..end] {
            if (hashes[current] ^ hashes[other]).count_ones() <= NEARBY_DISTANCE
                && color_close(colors[current], colors[other])
            {
                sets.join(current, other);
            }
        }
    }

    let mut roots = Vec::with_capacity(count);
    let mut sizes = HashMap::new();
    for item in 0..count {
        let root = sets.root(item);
        roots.push(root);
        *sizes.entry(root).or_insert(0usize) += 1;
    }
    let mut labels = HashMap::new();
    let mut output = Vec::with_capacity(count);
    for root in roots {
        if sizes[&root] < 2 {
            output.push(0);
        } else {
            let next = labels.len() as u32 + 1;
            output.push(*labels.entry(root).or_insert(next));
        }
    }
    let group_count = labels.len();
    (output, group_count)
}

/// Writes one group number per photo. Zero means no similar photo found.
#[no_mangle]
pub unsafe extern "C" fn group_photos(
    hashes: *const u64,
    colors: *const u32,
    timestamps: *const i64,
    count: usize,
    output: *mut u32,
) -> usize {
    if count == 0 { return 0; }
    if hashes.is_null() || colors.is_null() || timestamps.is_null() || output.is_null() { return 0; }
    let hashes = std::slice::from_raw_parts(hashes, count);
    let colors = std::slice::from_raw_parts(colors, count);
    let timestamps = std::slice::from_raw_parts(timestamps, count);
    let (labels, group_count) = group(hashes, colors, timestamps);
    std::slice::from_raw_parts_mut(output, count).copy_from_slice(&labels);
    group_count
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_images_group() {
        let (labels, count) = group(&[0, 0, u64::MAX], &[0x112233, 0x112233, 0xffffff], &[0, 100_000, 0]);
        assert_eq!(count, 1);
        assert_eq!(labels, [1, 1, 0]);
    }

    #[test]
    fn nearby_hashes_with_different_colors_stay_apart() {
        let (labels, count) = group(&[0, 1], &[0, 0xffffff], &[0, 1]);
        assert_eq!(count, 0);
        assert_eq!(labels, [0, 0]);
    }

    #[test]
    fn nearby_dates_allow_more_visual_difference() {
        let hashes = [0, (1u64 << 9) - 1];
        let colors = [0x112233, 0x112233];
        let (nearby, nearby_count) = group(&hashes, &colors, &[0, NEARBY_SECONDS]);
        assert_eq!(nearby_count, 1);
        assert_eq!(nearby, [1, 1]);
        let (distant, distant_count) = group(&hashes, &colors, &[0, NEARBY_SECONDS + 1]);
        assert_eq!(distant_count, 0);
        assert_eq!(distant, [0, 0]);
    }

    #[test]
    fn strong_visual_match_ignores_date() {
        let (labels, count) = group(&[0, 1], &[0x112233, 0x112233], &[i64::MIN, 1_000_000]);
        assert_eq!(count, 1);
        assert_eq!(labels, [1, 1]);
    }

    #[test]
    fn signature_has_consistent_brightness_direction() {
        let mut pixels = [0u8; PIXEL_BYTES];
        for (i, pixel) in pixels.chunks_exact_mut(4).enumerate() {
            pixel[..3].fill((i % WIDTH * 20) as u8);
            pixel[3] = 255;
        }
        let mut color = 0;
        let signature = unsafe { image_signature(pixels.as_ptr(), pixels.len(), &mut color) };
        assert_eq!(signature, 0);
        assert_ne!(color, 0);
    }
}
