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

fn extract(data: &[u8], extension: &str) -> Option<String> {
    use fastdoc_engine::render::office::{
        docx_reader::DocxReader, office_block::OfficeReadResult,
        office_markdown_serializer::OfficeMarkdownSerializer, odt_reader::OdtReader,
        zip_archive::ZipArchive,
    };

    let archive = ZipArchive::new(swiftshim::Data::fromBytes(data.to_vec())).ok()?;
    let result: OfficeReadResult = match extension.to_lowercase().as_str() {
        "docx" | "docm" | "dotx" | "dotm" => DocxReader::read(&archive).ok()?,
        "odt" => OdtReader::read(&archive).ok()?,
        _ => return None,
    };
    Some(OfficeMarkdownSerializer::serialize(&result.blocks, &result.footnotes))
}
