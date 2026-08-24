//! The C ABI the macOS host calls the ported engine through.
//!
//! Shaped after `rhwp_native_ffi` on purpose (`docs/BUILD-RHWP.md` §3): every string this library
//! returns is owned by it and freed by `fastdoc_string_free`, never by the caller's allocator. The
//! host already speaks that protocol for HWP, so it learns nothing new here.
//!
//! Deliberately narrow. The first function is the path that has already been checked against the
//! shipped reader on 551 real documents, so the first thing crossing this boundary is something
//! whose right answer is known — a link that compiles proves nothing, and a link that returns the
//! wrong bytes silently is what this exists to rule out.

use fastdoc_engine::render::office::hwp_reader::mapping::HwpReader;
use fastdoc_engine::render::office::{
    docx_reader::DocxReader, odt_reader::OdtReader, office_block::OfficeReadResult,
    office_markdown_serializer::OfficeMarkdownSerializer, zip_archive::ZipArchive,
};
use std::ffi::{c_char, CStr, CString};

/// Reads an office document and returns its Markdown extraction, or NULL.
///
/// `bytes`/`len` are the whole file. `extension_` is the file's extension WITHOUT a dot, lowercase
/// or not — `docx`, `ODT`. The returned string is UTF-8 and must be handed to
/// `fastdoc_string_free`.
///
/// NULL means the document could not be read. It does NOT distinguish why: the caller that needs a
/// reason is the CLI, which does its own reading, and a reason string crossing here would have to
/// be freed on a path the caller takes only on failure — the shape most likely to leak.
///
/// # Safety
/// `bytes` must point to `len` readable bytes and `extension_` must be a NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_extract_markdown(
    bytes: *const u8,
    len: usize,
    extension_: *const c_char,
) -> *mut c_char {
    if bytes.is_null() || extension_.is_null() {
        return std::ptr::null_mut();
    }
    let data = std::slice::from_raw_parts(bytes, len);
    let Ok(extension) = CStr::from_ptr(extension_).to_str() else {
        return std::ptr::null_mut();
    };

    // A panic must not cross the ABI — unwinding into Swift's frames is undefined behaviour, and
    // this engine still has `todo!()`s in reach of some documents. Catching turns "the host dies
    // with no message" into "this document could not be read", which is a truth the host can act
    // on.
    let extracted = std::panic::catch_unwind(|| extract(data, extension));
    match extracted {
        Ok(Some(markdown)) => match CString::new(markdown) {
            Ok(c) => c.into_raw(),
            // A NUL inside the text would truncate the document at that byte on the C side.
            Err(_) => std::ptr::null_mut(),
        },
        _ => std::ptr::null_mut(),
    }
}

/// Reads an office document and returns it as the JSON envelope a host decodes, or NULL.
///
/// Same ownership and same NULL-means-no as `fastdoc_extract_markdown`. NULL here also covers a
/// document the engine READ but cannot hand over intact — one carrying decoded pictures or a
/// resolved face — because a host that received it silently short those things would render a
/// plausible, wrong document. Falling back to its own reader is the correct response, and NULL is
/// what asks for it.
///
/// # Safety
/// `bytes` must point to `len` readable bytes and `extension_` must be a NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_read_office_json(
    bytes: *const u8,
    len: usize,
    extension_: *const c_char,
) -> *mut c_char {
    if bytes.is_null() || extension_.is_null() {
        return std::ptr::null_mut();
    }
    let data = std::slice::from_raw_parts(bytes, len);
    let Ok(extension) = CStr::from_ptr(extension_).to_str() else {
        return std::ptr::null_mut();
    };
    let read = std::panic::catch_unwind(|| {
        let result = read_office(data, extension)?;
        fastdoc_engine::render::office::office_export::to_json(&result).ok()
    });
    match read {
        Ok(Some(json)) => match CString::new(json) {
            Ok(c) => c.into_raw(),
            Err(_) => std::ptr::null_mut(),
        },
        _ => std::ptr::null_mut(),
    }
}

/// The document's own default BODY run size in points — the other half of the typography's
/// font-size model, which the host asks for separately because the read result does not carry it
/// for a zip-backed document.
///
/// Returns 11 for anything it cannot read, which is the same value the host's own fallback used:
/// the number Word ASSUMES when a document declares none (see invariant 62's third case — 11 is
/// what Word WRITES, 10 is what it assumes, and this is the reader's declared-nothing default).
///
/// # Safety
/// `bytes` must point to `len` readable bytes and `extension_` must be a NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_office_default_body_font_size(
    bytes: *const u8,
    len: usize,
    extension_: *const c_char,
) -> f64 {
    const DECLARED_NOTHING: f64 = 11.0;
    if bytes.is_null() || extension_.is_null() {
        return DECLARED_NOTHING;
    }
    let data = std::slice::from_raw_parts(bytes, len);
    let Ok(extension) = CStr::from_ptr(extension_).to_str() else {
        return DECLARED_NOTHING;
    };
    std::panic::catch_unwind(|| {
        let Ok(archive) = ZipArchive::new(swiftshim::Data::fromBytes(data.to_vec())) else {
            return DECLARED_NOTHING;
        };
        match extension.to_lowercase().as_str() {
            "docx" | "docm" | "dotx" | "dotm" => DocxReader::document_default_body_font_size(&archive),
            "odt" => OdtReader::document_default_body_font_size(&archive),
            _ => DECLARED_NOTHING,
        }
    })
    .unwrap_or(DECLARED_NOTHING)
}

/// Frees a string this library returned. Passing anything else is undefined.
///
/// # Safety
/// `s` must be NULL or a pointer this library returned and has not already freed.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// swift: `DocumentTypes.readOffice`'s reader half — the dispatch only, WITHOUT
/// `.resolvingFontSubstitution()`, which is AppKit's and stays on the host.
fn read_office(data: &[u8], extension: &str) -> Option<OfficeReadResult> {
    // HWP is answered BEFORE the archive is opened, not after. `.hwp` is CFB binary rather than a
    // zip, so opening one as an archive fails and the reader would never be reached — which is how
    // the host's own dispatch does it too (`DocumentTypes.isHwp` branches ahead of `ZipArchive`).
    if matches!(extension.to_lowercase().as_str(), "hwp" | "hwpx") {
        return HwpReader::read(&swiftshim::Data::fromBytes(data.to_vec())).ok();
    }
    let archive = ZipArchive::new(swiftshim::Data::fromBytes(data.to_vec())).ok()?;
    match extension.to_lowercase().as_str() {
        "docx" | "docm" | "dotx" | "dotm" => DocxReader::read(&archive).ok(),
        "odt" => OdtReader::read(&archive).ok(),
        _ => None,
    }
}

fn extract(data: &[u8], extension: &str) -> Option<String> {
    let result = read_office(data, extension)?;
    Some(OfficeMarkdownSerializer::serialize(&result.blocks, &result.footnotes))
}
