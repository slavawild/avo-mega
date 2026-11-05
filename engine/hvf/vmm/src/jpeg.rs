//! Camera JPEGs rewritten as the plainest baseline JPEG, losslessly.
//!
//! Android's external camera HAL decodes each frame with libyuv's
//! MJPGToI420. The Mac's encoders (ImageIO, Core Image) write JPEGs with a
//! restart marker after every row of blocks (DRI), Photoshop and Exif APP
//! segments and Huffman tables of their own; about half of a movie's frames
//! came back from the HAL as "Convert V4L2 frame to YU12 failed! res 1",
//! while its own gray frames (camera.rs, plain baseline) never did.
//!
//! `baseline` keeps the picture to the bit: it reads the quantized DCT
//! coefficients out of the entropy-coded data and writes them again,
//! without restart intervals, with the standard tables of ITU T.81 Annex K
//! (luma for the first component, chroma for the others), and only the
//! segments a decoder needs: DQT, SOF0, DHT, SOS. Anything it does not
//! take (progressive, arithmetic, 12-bit, several scans, damaged data)
//! gives None, and the frame goes as it came.

/// The Huffman code of each symbol: (code, length); length 0 for none.
struct Encoder {
    codes: [(u16, u8); 256],
}

/// A table for decoding (T.81 F.2.2.3): per code length, the largest code
/// and where its values start; codes of up to `FAST` bits also by lookup.
struct Decoder {
    maxcode: [i32; 17],
    valptr: [i32; 17],
    mincode: [i32; 17],
    values: Vec<u8>,
    /// By the next `FAST` bits: (code length, value); length 0 for longer codes.
    fast: Vec<(u8, u8)>,
}

const FAST: u32 = 9;

impl Decoder {
    fn new(counts: &[u8; 16], values: &[u8]) -> Option<Decoder> {
        if counts.iter().map(|&n| n as usize).sum::<usize>() != values.len() {
            return None;
        }
        let mut maxcode = [-1i32; 17];
        let (mut valptr, mut mincode) = ([0i32; 17], [0i32; 17]);
        let mut fast = vec![(0u8, 0u8); 1 << FAST];
        let (mut code, mut index) = (0i32, 0i32);
        for length in 1..=16 {
            let count = counts[length - 1] as i32;
            if count > 0 {
                valptr[length] = index;
                mincode[length] = code;
                if length as u32 <= FAST {
                    let shift = FAST - length as u32;
                    for i in 0..count {
                        let first = ((code + i) as usize) << shift;
                        fast[first..first + (1 << shift)].fill((length as u8, values[(index + i) as usize]));
                    }
                }
                code += count;
                index += count;
                maxcode[length] = code - 1;
            }
            if code > 1 << length {
                return None;
            }
            code <<= 1;
        }
        Some(Decoder { maxcode, valptr, mincode, values: values.to_vec(), fast })
    }

    fn decode(&self, reader: &mut Reader) -> Option<u8> {
        let bits = reader.peek16();
        let (length, value) = self.fast[(bits >> (16 - FAST)) as usize];
        if length > 0 {
            reader.consume(length as u32)?;
            return Some(value);
        }
        for length in FAST as usize + 1..=16 {
            let code = (bits >> (16 - length)) as i32;
            if code <= self.maxcode[length] {
                reader.consume(length as u32)?;
                return self.values.get((self.valptr[length] + code - self.mincode[length]) as usize).copied();
            }
        }
        None
    }
}

impl Encoder {
    fn new(counts: &[u8; 16], values: &[u8]) -> Encoder {
        let mut codes = [(0u16, 0u8); 256];
        let (mut code, mut index) = (0u16, 0usize);
        for length in 1..=16u8 {
            for _ in 0..counts[length as usize - 1] {
                codes[values[index] as usize] = (code, length);
                code += 1;
                index += 1;
            }
            code <<= 1;
        }
        Encoder { codes }
    }
}

/// ITU T.81 Annex K.3: luma DC, chroma DC, luma AC, chroma AC.
const DC_LUMA_COUNTS: [u8; 16] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const DC_CHROMA_COUNTS: [u8; 16] = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
const DC_VALUES: [u8; 12] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const AC_LUMA_COUNTS: [u8; 16] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d];
const AC_LUMA_VALUES: [u8; 162] = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
];
const AC_CHROMA_COUNTS: [u8; 16] = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77];
const AC_CHROMA_VALUES: [u8; 162] = [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
];

/// Entropy-coded data through a 64-bit buffer: stuffed 0xFF 0x00 is
/// 0xFF; it stops at a marker (the end, or a restart marker `restart`
/// steps over), and reading past it fails.
struct Reader<'a> {
    data: &'a [u8],
    at: usize,
    bits: u64,
    count: u32,
    /// At a marker (or the data's end): nothing more to fill.
    stopped: bool,
}

impl Reader<'_> {
    fn fill(&mut self) {
        while self.count <= 56 && !self.stopped {
            let Some(&byte) = self.data.get(self.at) else {
                self.stopped = true;
                break;
            };
            if byte == 0xff {
                if self.data.get(self.at + 1) != Some(&0) {
                    self.stopped = true;
                    break;
                }
                self.at += 2;
            } else {
                self.at += 1;
            }
            self.bits = (self.bits << 8) | byte as u64;
            self.count += 8;
        }
    }

    /// The next 16 bits, zeros past the end.
    fn peek16(&mut self) -> u32 {
        if self.count < 16 {
            self.fill();
        }
        if self.count >= 16 {
            ((self.bits >> (self.count - 16)) & 0xffff) as u32
        } else {
            ((self.bits << (16 - self.count)) & 0xffff) as u32
        }
    }

    fn consume(&mut self, count: u32) -> Option<()> {
        if self.count < count {
            self.fill();
            if self.count < count {
                return None;
            }
        }
        self.count -= count;
        Some(())
    }

    fn bits(&mut self, count: u32) -> Option<u32> {
        if count == 0 {
            return Some(0);
        }
        self.consume(count)?;
        Some(((self.bits >> self.count) & ((1u64 << count) - 1)) as u32)
    }

    /// What is left of the byte is padding; then RSTn (after any fill bytes).
    fn restart(&mut self, n: u8) -> Option<()> {
        self.fill();
        if self.count >= 8 || !self.stopped {
            return None;
        }
        self.count = 0;
        self.bits = 0;
        while self.data.get(self.at) == Some(&0xff) && self.data.get(self.at + 1) == Some(&0xff) {
            self.at += 1;
        }
        if self.data.get(self.at..self.at + 2)? != [0xff, 0xd0 + (n & 7)] {
            return None;
        }
        self.at += 2;
        self.stopped = false;
        Some(())
    }
}

/// Entropy-coded output: 0xFF is stuffed with 0x00; the last byte is
/// padded with ones.
struct Writer {
    out: Vec<u8>,
    bits: u64,
    count: u32,
}

impl Writer {
    fn put(&mut self, value: u32, length: u32) {
        if length == 0 {
            return;
        }
        self.bits = (self.bits << length) | (value as u64 & ((1u64 << length) - 1));
        self.count += length;
        while self.count >= 8 {
            self.count -= 8;
            let byte = (self.bits >> self.count) as u8;
            self.out.push(byte);
            if byte == 0xff {
                self.out.push(0);
            }
        }
        self.bits &= (1u64 << self.count) - 1;
    }

    fn finish(mut self) -> Vec<u8> {
        if self.count > 0 {
            let pad = 8 - self.count;
            self.put((1 << pad) - 1, pad);
        }
        self.out
    }
}

/// The bits a coefficient's magnitude takes (its category, T.81 F.1.2.1).
fn category(value: i32) -> u32 {
    32 - value.unsigned_abs().leading_zeros()
}

/// `category` bits read back into a signed value (T.81 F.2.2.1 EXTEND).
fn extend(bits: u32, category: u32) -> i32 {
    if category == 0 {
        0
    } else if bits < 1 << (category - 1) {
        bits as i32 - (1 << category) + 1
    } else {
        bits as i32
    }
}

fn segment(out: &mut Vec<u8>, marker: u8, body: &[u8]) {
    out.extend_from_slice(&[0xff, marker]);
    out.extend_from_slice(&((body.len() + 2) as u16).to_be_bytes());
    out.extend_from_slice(body);
}

struct Component {
    id: u8,
    h: usize,
    v: usize,
}

/// `jpeg` as a plain baseline JPEG of the same picture (see the module);
/// None when it is not one this can read.
pub fn baseline(jpeg: &[u8]) -> Option<Vec<u8>> {
    if jpeg.get(..2)? != [0xff, 0xd8] {
        return None;
    }
    let mut tables: Vec<Vec<u8>> = Vec::new();
    let mut frame: Option<(Vec<u8>, usize, usize, Vec<Component>)> = None;
    // Index: class (0 DC, 1 AC) × 4 + table id.
    let mut decoders: [Option<Decoder>; 8] = Default::default();
    let mut interval = 0usize;
    let mut at = 2;
    let scan = loop {
        if *jpeg.get(at)? != 0xff {
            return None;
        }
        let marker = *jpeg.get(at + 1)?;
        if marker == 0xff {
            at += 1;
            continue;
        }
        let length = u16::from_be_bytes([*jpeg.get(at + 2)?, *jpeg.get(at + 3)?]) as usize;
        let body = jpeg.get(at + 4..(at + 2 + length).max(at + 4))?;
        at += 2 + length;
        match marker {
            0xdb => {
                // 8-bit tables only (16-bit ones are not baseline).
                let mut rest = body;
                while !rest.is_empty() {
                    if rest[0] >> 4 != 0 || rest.len() < 65 {
                        return None;
                    }
                    rest = &rest[65..];
                }
                tables.push(body.to_vec());
            }
            0xc0 | 0xc1 => {
                if body.len() < 6 || body[0] != 8 {
                    return None;
                }
                let height = u16::from_be_bytes([body[1], body[2]]) as usize;
                let width = u16::from_be_bytes([body[3], body[4]]) as usize;
                let count = body[5] as usize;
                if body.len() != 6 + 3 * count || !(1..=4).contains(&count) || width == 0 || height == 0 {
                    return None;
                }
                let components: Vec<Component> = body[6..]
                    .chunks(3)
                    .map(|c| Component { id: c[0], h: (c[1] >> 4) as usize, v: (c[1] & 15) as usize })
                    .collect();
                if components.iter().any(|c| !(1..=4).contains(&c.h) || !(1..=4).contains(&c.v)) {
                    return None;
                }
                frame = Some((body.to_vec(), width, height, components));
            }
            0xc2..=0xcf if ![0xc4, 0xc8, 0xcc].contains(&marker) => return None,
            0xc4 => {
                let mut rest = body;
                while !rest.is_empty() {
                    let class = (rest[0] >> 4) as usize;
                    let id = (rest[0] & 15) as usize;
                    let counts: [u8; 16] = rest.get(1..17)?.try_into().ok()?;
                    let total: usize = counts.iter().map(|&n| n as usize).sum();
                    let values = rest.get(17..17 + total)?;
                    if class > 1 || id > 3 {
                        return None;
                    }
                    decoders[class * 4 + id] = Some(Decoder::new(&counts, values)?);
                    rest = &rest[17 + total..];
                }
            }
            0xdd => interval = u16::from_be_bytes([*body.first()?, *body.get(1)?]) as usize,
            0xda => break body,
            0xd9 => return None,
            _ => {}
        }
    };
    let (sof, width, height, components) = frame?;
    // One scan of every component, baseline (Ss 0, Se 63, no approximation).
    let count = *scan.first()? as usize;
    if count != components.len() || scan.len() != 4 + 2 * count || scan[1 + 2 * count..] != [0, 63, 0] {
        return None;
    }
    let mut order = Vec::new();
    for c in scan[1..1 + 2 * count].chunks(2) {
        let index = components.iter().position(|component| component.id == c[0])?;
        let (dc, ac) = ((c[1] >> 4) as usize, (c[1] & 15) as usize);
        if dc > 3 || ac > 3 || decoders[dc].is_none() || decoders[4 + ac].is_none() {
            return None;
        }
        order.push((index, dc, 4 + ac));
    }

    let dc_out = [Encoder::new(&DC_LUMA_COUNTS, &DC_VALUES), Encoder::new(&DC_CHROMA_COUNTS, &DC_VALUES)];
    let ac_out = [Encoder::new(&AC_LUMA_COUNTS, &AC_LUMA_VALUES), Encoder::new(&AC_CHROMA_COUNTS, &AC_CHROMA_VALUES)];
    let mut reader = Reader { data: &jpeg[at..], at: 0, bits: 0, count: 0, stopped: false };
    let mut writer = Writer { out: Vec::with_capacity(jpeg.len()), bits: 0, count: 0 };
    let mut read_dc = vec![0i32; components.len()];
    let mut written_dc = vec![0i32; components.len()];

    // Blocks of each component per MCU (interleaved), or one block a MCU
    // of a lone component's own grid.
    let (hmax, vmax) = (components.iter().map(|c| c.h).max()?, components.iter().map(|c| c.v).max()?);
    let (mcus, blocks): (usize, Vec<(usize, usize, usize, usize)>) = if count == 1 {
        let c = &components[0];
        let columns = (width * c.h).div_ceil(hmax).div_ceil(8);
        let rows = (height * c.v).div_ceil(vmax).div_ceil(8);
        (columns * rows, vec![order[0]].into_iter().map(|(i, dc, ac)| (i, dc, ac, 1)).collect())
    } else {
        let mcus = width.div_ceil(8 * hmax) * height.div_ceil(8 * vmax);
        (mcus, order.iter().map(|&(i, dc, ac)| (i, dc, ac, components[i].h * components[i].v)).collect())
    };

    let mut coefficients = [0i32; 64];
    for mcu in 0..mcus {
        if interval > 0 && mcu > 0 && mcu % interval == 0 {
            reader.restart(((mcu / interval - 1) % 8) as u8)?;
            read_dc.iter_mut().for_each(|dc| *dc = 0);
        }
        for &(index, dc_table, ac_table, count) in &blocks {
            let (dc_in, ac_in) = (decoders[dc_table].as_ref()?, decoders[ac_table].as_ref()?);
            let side = usize::from(index != 0);
            for _ in 0..count {
                coefficients.fill(0);
                let size = dc_in.decode(&mut reader)? as u32;
                if size > 11 {
                    return None;
                }
                read_dc[index] += extend(reader.bits(size)?, size);
                coefficients[0] = read_dc[index];
                let mut k = 1;
                while k < 64 {
                    let symbol = ac_in.decode(&mut reader)?;
                    let (run, size) = ((symbol >> 4) as usize, (symbol & 15) as u32);
                    if size == 0 {
                        if run == 15 {
                            k += 16;
                            continue;
                        }
                        break;
                    }
                    k += run;
                    if k > 63 || size > 10 {
                        return None;
                    }
                    coefficients[k] = extend(reader.bits(size)?, size);
                    k += 1;
                }

                let diff = coefficients[0] - written_dc[index];
                written_dc[index] = coefficients[0];
                let size = category(diff);
                let (code, length) = dc_out[side].codes[size as usize];
                writer.put(code as u32, length as u32);
                writer.put(if diff < 0 { (diff - 1) as u32 } else { diff as u32 }, size);
                let mut run = 0;
                for &value in &coefficients[1..] {
                    if value == 0 {
                        run += 1;
                        continue;
                    }
                    while run > 15 {
                        let (code, length) = ac_out[side].codes[0xf0];
                        writer.put(code as u32, length as u32);
                        run -= 16;
                    }
                    let size = category(value);
                    let (code, length) = ac_out[side].codes[(run << 4) | size as usize];
                    if length == 0 {
                        return None;
                    }
                    writer.put(code as u32, length as u32);
                    writer.put(if value < 0 { (value - 1) as u32 } else { value as u32 }, size);
                    run = 0;
                }
                if run > 0 {
                    let (code, length) = ac_out[side].codes[0x00];
                    writer.put(code as u32, length as u32);
                }
            }
        }
    }
    let data = writer.finish();

    let mut out = Vec::with_capacity(data.len() + 1024);
    out.extend_from_slice(&[0xff, 0xd8]);
    for table in &tables {
        segment(&mut out, 0xdb, table);
    }
    segment(&mut out, 0xc0, &sof);
    let mut dht = Vec::new();
    for (class_id, counts, values) in [
        (0x00, &DC_LUMA_COUNTS, &DC_VALUES[..]),
        (0x01, &DC_CHROMA_COUNTS, &DC_VALUES[..]),
        (0x10, &AC_LUMA_COUNTS, &AC_LUMA_VALUES[..]),
        (0x11, &AC_CHROMA_COUNTS, &AC_CHROMA_VALUES[..]),
    ] {
        dht.push(class_id);
        dht.extend_from_slice(counts);
        dht.extend_from_slice(values);
    }
    segment(&mut out, 0xc4, &dht);
    let mut sos = vec![count as u8];
    for &(index, _, _) in &order {
        sos.push(components[index].id);
        sos.push(if index == 0 { 0x00 } else { 0x11 });
    }
    sos.extend_from_slice(&[0, 63, 0]);
    segment(&mut out, 0xda, &sos);
    out.extend_from_slice(&data);
    out.extend_from_slice(&[0xff, 0xd9]);
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 4:2:0 JPEG of 40×24 noise with a restart marker every MCU and
    /// optimized Huffman tables (libjpeg via Pillow: quality 80,
    /// subsampling 2, optimize, restart_marker_blocks 1).
    const RESTARTS: &[u8] = include_bytes!("../testdata/restarts.jpg");
    /// The same picture as libjpeg writes it plainly (no restarts, its
    /// standard tables): the same quantized coefficients.
    const PLAIN: &[u8] = include_bytes!("../testdata/plain.jpg");

    #[test]
    fn standard_tables_cover_every_symbol() {
        for values in [&AC_LUMA_VALUES, &AC_CHROMA_VALUES] {
            let mut seen: Vec<u8> = values.to_vec();
            seen.sort();
            seen.dedup();
            let mut all: Vec<u8> = vec![0x00, 0xf0];
            all.extend((0..16u8).flat_map(|run| (1..=10u8).map(move |size| run << 4 | size)));
            all.sort();
            assert_eq!(seen, all);
        }
        assert_eq!(AC_LUMA_COUNTS.iter().map(|&n| n as usize).sum::<usize>(), 162);
        assert_eq!(AC_CHROMA_COUNTS.iter().map(|&n| n as usize).sum::<usize>(), 162);
    }

    #[test]
    fn restarts_go_and_the_picture_stays() {
        let out = baseline(RESTARTS).unwrap();
        assert_eq!(crate::camera::jpeg_kind(&out), "40x24 sof0 h2v2,h1v1,h1v1");
        assert!(!out.windows(2).any(|w| w[0] == 0xff && (0xd0..=0xd7).contains(&w[1])));
        // The same coefficients as the plain encoding of the same picture.
        assert_eq!(baseline(PLAIN).unwrap(), out);
        // Rewriting again changes nothing.
        assert_eq!(baseline(&out).unwrap(), out);
    }

    #[test]
    fn gray_frames_and_others_come_through() {
        let gray = crate::camera::gray_jpeg(64, 48, 100);
        let out = baseline(&gray).unwrap();
        assert_eq!(crate::camera::jpeg_kind(&out), "64x48 sof0 h1v1");
        assert!(baseline(b"\xff\xd8\xff\xd9").is_none());
        assert!(baseline(&RESTARTS[..RESTARTS.len() / 2]).is_none());
        assert!(baseline(b"not a jpeg").is_none());
    }
}
