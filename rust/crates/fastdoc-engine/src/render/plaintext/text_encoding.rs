//! Reference: Sources/FastDocReader/App/TextEncodingDetector.swift (repository baseline).
//! Pure, reversible best-effort decoding. Platform-specific system guesses are omitted.

use encoding_rs::{BIG5, EUC_KR, GBK, SHIFT_JIS};
use std::borrow::Cow;

pub(super) fn decode(bytes: &[u8]) -> Cow<'_, str> {
    if let Some(text) = from_bom(bytes) {
        return Cow::Owned(text);
    }
    // ASCII-only UTF-16 is also valid UTF-8 containing NULs; sniff its strong NUL pattern
    // before the UTF-8 fast path so a Windows text file does not display embedded NULs.
    if let Some(text) = bomless_utf16(bytes) {
        return Cow::Owned(text);
    }
    if let Ok(text) = std::str::from_utf8(bytes) {
        return Cow::Borrowed(text);
    }
    for (encoding, script) in [(EUC_KR, 0), (SHIFT_JIS, 1), (GBK, 2), (BIG5, 2)] {
        if let Some(text) = encoding.decode_without_bom_handling_and_without_replacement(bytes) {
            let matches = text.chars().any(|c| match script {
                0 => matches!(c as u32, 0xac00..=0xd7a3 | 0x1100..=0x11ff | 0x3130..=0x318f),
                1 => matches!(c as u32, 0x3040..=0x30ff),
                _ => matches!(c as u32, 0x4e00..=0x9fff),
            });
            if matches {
                let (encoded, _, errors) = encoding.encode(&text);
                if !errors && encoded.as_ref() == bytes {
                    return text;
                }
            }
        }
    }
    // Latin-1 has a one-to-one inverse for every byte, including arbitrary binary.
    Cow::Owned(bytes.iter().map(|&b| char::from(b)).collect())
}

fn utf16(bytes: &[u8], little: bool) -> Option<String> {
    if bytes.len() % 2 != 0 {
        return None;
    }
    let units = bytes
        .chunks_exact(2)
        .map(|b| {
            if little {
                u16::from_le_bytes([b[0], b[1]])
            } else {
                u16::from_be_bytes([b[0], b[1]])
            }
        })
        .collect::<Vec<_>>();
    String::from_utf16(&units).ok()
}

fn utf32(bytes: &[u8], little: bool) -> Option<String> {
    if bytes.len() % 4 != 0 {
        return None;
    }
    bytes
        .chunks_exact(4)
        .map(|b| {
            let b = [b[0], b[1], b[2], b[3]];
            char::from_u32(if little {
                u32::from_le_bytes(b)
            } else {
                u32::from_be_bytes(b)
            })
        })
        .collect()
}

fn from_bom(bytes: &[u8]) -> Option<String> {
    if let Some(rest) = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]) {
        return std::str::from_utf8(rest).ok().map(str::to_owned);
    }
    for (bom, little) in [([0xff, 0xfe, 0, 0], true), ([0, 0, 0xfe, 0xff], false)] {
        if let Some(rest) = bytes.strip_prefix(&bom) {
            return utf32(rest, little);
        }
    }
    for (bom, little) in [([0xff, 0xfe], true), ([0xfe, 0xff], false)] {
        if let Some(rest) = bytes.strip_prefix(&bom) {
            return utf16(rest, little);
        }
    }
    None
}

fn bomless_utf16(bytes: &[u8]) -> Option<String> {
    let sample = &bytes[..bytes.len().min(4096)];
    if sample.len() < 4 {
        return None;
    }
    let (mut even, mut odd) = (0, 0);
    for (i, &b) in sample.iter().enumerate() {
        if b == 0 {
            if i % 2 == 0 {
                even += 1;
            } else {
                odd += 1;
            }
        }
    }
    let threshold = sample.len() / 2 / 2;
    if odd > threshold && even <= odd / 8 {
        return utf16(bytes, true);
    }
    if even > threshold && odd <= even / 8 {
        return utf16(bytes, false);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unicode_boms_and_regional_text_preserve_characters() {
        let text = "Hello 한글😀";
        for little in [true, false] {
            let mut bytes = if little {
                vec![0xff, 0xfe]
            } else {
                vec![0xfe, 0xff]
            };
            for unit in text.encode_utf16() {
                bytes.extend(if little {
                    unit.to_le_bytes()
                } else {
                    unit.to_be_bytes()
                });
            }
            assert_eq!(decode(&bytes), text);
        }
        assert_eq!(decode(b"\xef\xbb\xbfhello"), "hello");
        assert_eq!(decode(b"H\0e\0l\0l\0o\0"), "Hello");
        assert_eq!(decode(&[0xc7, 0xd1, 0xb1, 0xdb]), "한글");
        for little in [true, false] {
            let mut bytes = if little {
                vec![0xff, 0xfe, 0, 0]
            } else {
                vec![0, 0, 0xfe, 0xff]
            };
            for c in text.chars() {
                bytes.extend(if little {
                    (c as u32).to_le_bytes()
                } else {
                    (c as u32).to_be_bytes()
                });
            }
            assert_eq!(decode(&bytes), text);
        }
    }

    #[test]
    fn binary_fallback_is_reversible_and_malformed_bom_keeps_every_byte() {
        let bytes = [0xff, 0, 0xfe, 0x80, 0x81];
        let text = decode(&bytes);
        assert_eq!(text.chars().map(|c| c as u8).collect::<Vec<_>>(), bytes);
        let malformed = [0xff, 0xfe, 0xff];
        assert_eq!(
            decode(&malformed)
                .chars()
                .map(|c| c as u8)
                .collect::<Vec<_>>(),
            malformed
        );
    }
}
