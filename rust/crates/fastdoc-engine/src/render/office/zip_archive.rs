//! swift: Render/Office/ZipArchive.swift
//! swift-range: 1-2

use swiftshim::{Data, NSRange};

/// A read-only ZIP container reader: parses just enough of the format to list and extract entries
/// by name, which is all `.docx`/`.xlsx`/`.pptx` need (they are ZIP containers holding XML parts).
/// No third-party dependency — the format needs exactly three record types, and this stays small
/// enough to read end to end: an End Of Central Directory record anchors a table of Central
/// Directory entries, each of which points at a Local File Header that precedes the entry's bytes.
///
/// A `struct`, not an `enum` namespace: parsing the central directory is real work (a corrupt or
/// Zip64 archive throws), so this holds the parsed table as state instead of re-deriving it per call.
// swift: Render/Office/ZipArchive.swift:3-12
pub struct ZipArchive {
    data: Data,
    entries_by_name: std::collections::HashMap<String, Entry>,
    order: Vec<String>,
}

// swift: Render/Office/ZipArchive.swift:13-35
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ZipArchiveError {
    /// No End Of Central Directory record found anywhere in the data — this isn't a ZIP file.
    MissingEndOfCentralDirectory,
    /// A record's declared offset or length reaches past the end of the data.
    Truncated,
    /// The archive (or one of its entries) uses Zip64 extensions, which this reader does not
    /// implement — refusing beats reading a 32-bit field that Zip64 repurposes as a "look
    /// elsewhere" sentinel (0xFFFF / 0xFFFFFFFF).
    Zip64Unsupported,
    /// Only stored (0) and deflated (8) are implemented.
    UnsupportedCompressionMethod(u16),
    /// General-purpose bit 0 is set — the entry's bytes are encrypted, and this type has no way
    /// to ask for a password.
    EncryptedEntry(String),
    /// No entry with this name is in the central directory.
    EntryNotFound(String),
    /// Bytes were present where a record was expected but did not parse as a valid one.
    CorruptEntry(String),
    /// The entry's declared uncompressed size exceeds `maxEntryUncompressedSize` — refused
    /// before any buffer sized from that (untrusted) number is allocated.
    EntryTooLarge { declared: usize, cap: usize },
}

// swift: Render/Office/ZipArchive.swift:36-44
struct Entry {
    name: String,
    compression_method: u16,
    compressed_size: u32,
    uncompressed_size: u32,
    local_header_offset: u32,
    general_purpose_bit_flag: u16,
}

// swift: Render/Office/ZipArchive.swift:45-55
const LOCAL_FILE_HEADER_SIGNATURE: u32 = 0x0403_4b50;
const CENTRAL_DIRECTORY_SIGNATURE: u32 = 0x0201_4b50;
const END_OF_CENTRAL_DIRECTORY_SIGNATURE: u32 = 0x0605_4b50;
const ZIP64_SENTINEL_16: u16 = 0xFFFF;
const ZIP64_SENTINEL_32: u32 = 0xFFFF_FFFF;
/// 512 MiB — comfortably above any legitimate single part in a real `.docx`/`.xlsx`/`.pptx`
/// (embedded media, a huge sheet), and a fixed ceiling on the allocation a declared-size lie can
/// force. These files arrive as untrusted input (email attachments), so the declared size is
/// checked against this BEFORE anything is allocated on its word.
pub const MAX_ENTRY_UNCOMPRESSED_SIZE: usize = 512 * 1024 * 1024;

impl ZipArchive {
    // swift: Render/Office/ZipArchive.swift:56-63
    /// The archive's entry names, in central-directory order (the order files were added — not
    /// necessarily alphabetical, and not required to match local-header order).
    pub fn entry_names(&self) -> &[String] {
        &self.order
    }

    // swift: Render/Office/ZipArchive.swift:64-86
    pub fn new(data: Data) -> Result<Self, ZipArchiveError> {
        let eocd_offset = Self::find_end_of_central_directory(&data)?;
        let total_entries = data.read_u16_le(eocd_offset + 10)?;
        let central_directory_size = data.read_u32_le(eocd_offset + 12)?;
        let central_directory_offset = data.read_u32_le(eocd_offset + 16)?;
        if total_entries == ZIP64_SENTINEL_16
            || central_directory_size == ZIP64_SENTINEL_32
            || central_directory_offset == ZIP64_SENTINEL_32
        {
            return Err(ZipArchiveError::Zip64Unsupported);
        }
        let mut by_name: std::collections::HashMap<String, Entry> = std::collections::HashMap::new();
        let mut names: Vec<String> = Vec::new();
        let mut cursor: usize = central_directory_offset as usize;
        for _ in 0..(total_entries as usize) {
            let entry = Self::read_central_directory_entry(&data, &mut cursor)?;
            names.push(entry.name.clone());
            by_name.insert(entry.name.clone(), entry);
        }
        Ok(ZipArchive { data, entries_by_name: by_name, order: names })
    }

    // swift: Render/Office/ZipArchive.swift:87-90
    pub fn from_url(url: &swiftshim::URL) -> Result<Self, ZipArchiveError> {
        // swift: Render/Office/ZipArchive.swift:88 — Data(contentsOf: url)
        let data = todo!("swift:88 Data(contentsOf: url)");
        #[allow(unreachable_code)]
        Self::new(data)
    }

    // swift: Render/Office/ZipArchive.swift:91-92
    pub fn contains(&self, name: &str) -> bool {
        self.entries_by_name.contains_key(name)
    }

    // swift: Render/Office/ZipArchive.swift:93-113
    pub fn data_for(&self, name: &str) -> Result<Data, ZipArchiveError> {
        let entry = self
            .entries_by_name
            .get(name)
            .ok_or_else(|| ZipArchiveError::EntryNotFound(name.to_string()))?;
        if entry.general_purpose_bit_flag & 0x1 != 0 {
            return Err(ZipArchiveError::EncryptedEntry(name.to_string()));
        }
        // Checked BEFORE the compressed bytes are even sliced out: the declared size is the
        // attacker-controlled number every downstream allocation (inflate's destination buffer
        // above all) would otherwise be sized from.
        if entry.uncompressed_size as usize > MAX_ENTRY_UNCOMPRESSED_SIZE {
            return Err(ZipArchiveError::EntryTooLarge {
                declared: entry.uncompressed_size as usize,
                cap: MAX_ENTRY_UNCOMPRESSED_SIZE,
            });
        }
        let compressed = Self::compressed_bytes(&self.data, entry)?;
        match entry.compression_method {
            0 => {
                if compressed.len() != entry.uncompressed_size as usize {
                    return Err(ZipArchiveError::CorruptEntry(name.to_string()));
                }
                Ok(compressed)
            }
            8 => Self::inflate(&compressed, entry.uncompressed_size as usize, name),
            other => Err(ZipArchiveError::UnsupportedCompressionMethod(other)),
        }
    }

    // MARK: End Of Central Directory

    /// Scans BACKWARD for the EOCD signature because the record ends with a variable-length comment,
    /// so it is not at a fixed offset from the end of the file. A signature match only counts if the
    /// comment-length field it carries lands exactly on the true end of the data — otherwise it is a
    /// coincidental byte sequence (inside a comment or entry data) and the scan keeps going.
    // swift: Render/Office/ZipArchive.swift:114-135
    fn find_end_of_central_directory(data: &Data) -> Result<usize, ZipArchiveError> {
        let record_size: usize = 22;
        if data.len() < record_size {
            return Err(ZipArchiveError::MissingEndOfCentralDirectory);
        }
        let max_comment_length: usize = 0xFFFF;
        let floor = data.len().saturating_sub(record_size + max_comment_length).max(0);
        let mut offset: i64 = data.len() as i64 - record_size as i64;
        while offset >= floor as i64 {
            let off = offset as usize;
            if data.read_u32_le(off)? == END_OF_CENTRAL_DIRECTORY_SIGNATURE {
                let comment_length = data.read_u16_le(off + 20)?;
                if off + record_size + comment_length as usize == data.len() {
                    return Ok(off);
                }
            }
            offset -= 1;
        }
        Err(ZipArchiveError::MissingEndOfCentralDirectory)
    }

    // MARK: Central directory

    // swift: Render/Office/ZipArchive.swift:136-166
    fn read_central_directory_entry(data: &Data, cursor: &mut usize) -> Result<Entry, ZipArchiveError> {
        let start = *cursor;
        if data.read_u32_le(start)? != CENTRAL_DIRECTORY_SIGNATURE {
            return Err(ZipArchiveError::CorruptEntry(format!(
                "central directory entry at offset {}",
                start
            )));
        }
        let general_purpose_bit_flag = data.read_u16_le(start + 8)?;
        let compression_method = data.read_u16_le(start + 10)?;
        let compressed_size = data.read_u32_le(start + 20)?;
        let uncompressed_size = data.read_u32_le(start + 24)?;
        let name_length = data.read_u16_le(start + 28)? as usize;
        let extra_length = data.read_u16_le(start + 30)? as usize;
        let comment_length = data.read_u16_le(start + 32)? as usize;
        let local_header_offset = data.read_u32_le(start + 42)?;
        let name_start = start + 46;
        if name_start + name_length > data.len() {
            return Err(ZipArchiveError::Truncated);
        }
        let name = String::from_utf8(
            data.subdata(Self::byte_range(name_start, name_length, data)).into_vec(),
        )
        .map_err(|_| {
            ZipArchiveError::CorruptEntry(format!("central directory entry at offset {}", start))
        })?;
        if compressed_size == ZIP64_SENTINEL_32
            || uncompressed_size == ZIP64_SENTINEL_32
            || local_header_offset == ZIP64_SENTINEL_32
        {
            return Err(ZipArchiveError::Zip64Unsupported);
        }
        *cursor = name_start + name_length + extra_length + comment_length;
        Ok(Entry {
            name,
            compression_method,
            compressed_size,
            uncompressed_size,
            local_header_offset,
            general_purpose_bit_flag,
        })
    }

    // MARK: Local file header + payload

    /// The compressed bytes for one entry. The name/extra lengths MUST come from the LOCAL header,
    /// not the central directory's — the two are allowed to differ (some writers pad the local extra
    /// field for alignment), and trusting the central directory's lengths here would skip the wrong
    /// number of bytes and hand back the tail of a name or extra field as if it were payload.
    // swift: Render/Office/ZipArchive.swift:167-185
    fn compressed_bytes(data: &Data, entry: &Entry) -> Result<Data, ZipArchiveError> {
        let start = entry.local_header_offset as usize;
        if data.read_u32_le(start)? != LOCAL_FILE_HEADER_SIGNATURE {
            return Err(ZipArchiveError::CorruptEntry(entry.name.clone()));
        }
        let name_length = data.read_u16_le(start + 26)? as usize;
        let extra_length = data.read_u16_le(start + 28)? as usize;
        let content_start = start + 30 + name_length + extra_length;
        let content_length = entry.compressed_size as usize;
        if content_start + content_length > data.len() {
            return Err(ZipArchiveError::Truncated);
        }
        Ok(data.subdata(Self::byte_range(content_start, content_length, data)))
    }

    // swift: Render/Office/ZipArchive.swift:186-189
    fn byte_range(offset: usize, length: usize, data: &Data) -> NSRange {
        NSRange::new(data.startIndex() + offset, length)
    }

    // MARK: Inflate

    /// `compression_decode_buffer` is a one-shot call with no signal of its own for "the source had
    /// more data than fit" — filling the destination exactly looks identical to the source genuinely
    /// ending there. Since the destination is always sized to the declared uncompressed size, an
    /// exact fill is the ORDINARY outcome for every well-formed entry, so it has to be verified:
    /// decode again into a buffer one byte larger. If that produces more bytes, the central
    /// directory's declared size undersold the real content, and the first decode was a truncated
    /// read wearing the costume of a complete one.
    // swift: Render/Office/ZipArchive.swift:190-206
    fn inflate(compressed: &Data, uncompressed_size: usize, name: &str) -> Result<Data, ZipArchiveError> {
        let decoded = Self::decode(compressed, uncompressed_size)?;
        if decoded.len() != uncompressed_size {
            return Err(ZipArchiveError::CorruptEntry(name.to_string()));
        }
        let recheck = Self::decode(compressed, uncompressed_size + 1)?;
        if recheck.len() != uncompressed_size {
            return Err(ZipArchiveError::CorruptEntry(name.to_string()));
        }
        Ok(decoded)
    }

    /// `COMPRESSION_ZLIB` in Apple's Compression framework is raw DEFLATE — exactly what a ZIP entry
    /// stores — not zlib-wrapped data, so no header is prepended or expected here.
    // swift: Render/Office/ZipArchive.swift:207-223
    fn decode(compressed: &Data, capacity: usize) -> Result<Data, ZipArchiveError> {
        if capacity == 0 {
            return Ok(Data::empty());
        }
        if compressed.isEmpty() {
            return Ok(Data::empty());
        }
        // swift:213-219 compression_decode_buffer(destBase, capacity, srcBase, compressed.count, nil, COMPRESSION_ZLIB)
        // Deferred: Apple's Compression framework has no Rust equivalent yet — phase B replaces
        // this with a real DEFLATE decoder (e.g. miniz_oxide). Do NOT substitute a crate here in
        // phase A; that is a design decision, not a transliteration.
        todo!("swift:207-221 Compression.inflate (compression_decode_buffer, COMPRESSION_ZLIB)")
    }
}

// swift: Render/Office/ZipArchive.swift:224-238
impl ZipArchiveError {
    pub fn error_description(&self) -> String {
        match self {
            ZipArchiveError::MissingEndOfCentralDirectory => {
                "Not a ZIP archive: no end-of-central-directory record found.".to_string()
            }
            ZipArchiveError::Truncated => {
                "ZIP archive is truncated: a record reaches past the end of the data.".to_string()
            }
            ZipArchiveError::Zip64Unsupported => {
                "This ZIP archive uses Zip64 extensions, which are not supported.".to_string()
            }
            ZipArchiveError::UnsupportedCompressionMethod(method) => {
                format!("Unsupported ZIP compression method {}.", method)
            }
            ZipArchiveError::EncryptedEntry(name) => {
                format!("\"{}\" is encrypted and cannot be read.", name)
            }
            ZipArchiveError::EntryNotFound(name) => {
                format!("\"{}\" was not found in the archive.", name)
            }
            ZipArchiveError::CorruptEntry(name) => format!("\"{}\" is corrupt.", name),
            ZipArchiveError::EntryTooLarge { declared, cap } => {
                format!("Declared size {} bytes exceeds the {}-byte limit.", declared, cap)
            }
        }
    }
}

impl std::fmt::Display for ZipArchiveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.error_description())
    }
}
impl std::error::Error for ZipArchiveError {}

// MARK: Little-endian field reads

// swift: Render/Office/ZipArchive.swift:239-254
trait DataLittleEndianReads {
    fn read_u16_le(&self, offset: usize) -> Result<u16, ZipArchiveError>;
    fn read_u32_le(&self, offset: usize) -> Result<u32, ZipArchiveError>;
}

impl DataLittleEndianReads for Data {
    // swift: Render/Office/ZipArchive.swift:242-246
    fn read_u16_le(&self, offset: usize) -> Result<u16, ZipArchiveError> {
        if offset + 2 > self.len() {
            return Err(ZipArchiveError::Truncated);
        }
        let base = self.startIndex() + offset;
        Ok((self.byte_at(base) as u16) | ((self.byte_at(base + 1) as u16) << 8))
    }

    // swift: Render/Office/ZipArchive.swift:248-253
    fn read_u32_le(&self, offset: usize) -> Result<u32, ZipArchiveError> {
        if offset + 4 > self.len() {
            return Err(ZipArchiveError::Truncated);
        }
        let base = self.startIndex() + offset;
        Ok((self.byte_at(base) as u32)
            | ((self.byte_at(base + 1) as u32) << 8)
            | ((self.byte_at(base + 2) as u32) << 16)
            | ((self.byte_at(base + 3) as u32) << 24))
    }
}
