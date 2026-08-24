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
use std::{cell::RefCell, fmt};

thread_local! {
    /// The most recent failure on this calling thread.
    ///
    /// The host calls `fastdoc_take_last_error` immediately after a NULL result. Keeping this
    /// thread-local prevents concurrent document reads from stealing one another's diagnostics;
    /// returning ownership through the existing string-free protocol prevents a borrowed pointer
    /// from outliving this slot.
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

#[derive(Debug)]
enum ReadOfficeError {
    InvalidArchive,
    UnsupportedExtension(String),
    Hwp(fastdoc_engine::render::office::hwp_reader::mapping::MapError),
    Reader(String),
    Export(String),
    InteriorNul,
    Panic,
}

impl fmt::Display for ReadOfficeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidArchive => f.write_str("the office archive is invalid"),
            Self::UnsupportedExtension(extension) => {
                write!(f, "unsupported office extension: {extension}")
            }
            Self::Hwp(error) => write!(f, "HWP reader failed: {error}"),
            Self::Reader(error) => write!(f, "office reader failed: {error}"),
            Self::Export(error) => write!(f, "office JSON export failed: {error}"),
            Self::InteriorNul => f.write_str("office JSON contained an interior NUL byte"),
            Self::Panic => f.write_str("office reader panicked"),
        }
    }
}

fn set_last_error(error: impl fmt::Display) {
    // CString can fail only when a diagnostic contains NUL. Replacing it keeps the failure
    // observable instead of recursively losing the error while trying to report it.
    let message = CString::new(error.to_string()).unwrap_or_else(|_| {
        CString::new("office reader failed with an invalid diagnostic").unwrap()
    });
    LAST_ERROR.with(|slot| *slot.borrow_mut() = Some(message));
}

fn clear_last_error() {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = None);
}

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
/// Same ownership and same NULL-means-no as `fastdoc_extract_markdown`. On NULL, the caller may
/// immediately call `fastdoc_take_last_error` on the same thread to distinguish parse, mapping,
/// export, and panic failures. NULL also covers a document the engine READ but cannot hand over
/// intact — one carrying decoded pictures or a resolved face — because a host that received it
/// silently short those things would render a plausible, wrong document.
///
/// # Safety
/// `bytes` must point to `len` readable bytes and `extension_` must be a NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_read_office_json(
    bytes: *const u8,
    len: usize,
    extension_: *const c_char,
) -> *mut c_char {
    clear_last_error();
    if bytes.is_null() || extension_.is_null() {
        set_last_error("invalid NULL argument");
        return std::ptr::null_mut();
    }
    let data = std::slice::from_raw_parts(bytes, len);
    let Ok(extension) = CStr::from_ptr(extension_).to_str() else {
        set_last_error("extension is not valid UTF-8");
        return std::ptr::null_mut();
    };
    let read = std::panic::catch_unwind(|| {
        let result = read_office(data, extension)?;
        let json = fastdoc_engine::render::office::office_export::to_json(&result)
            .map_err(|error| ReadOfficeError::Export(format!("{error:?}")))?;
        CString::new(json).map_err(|_| ReadOfficeError::InteriorNul)
    });
    match read {
        Ok(Ok(json)) => json.into_raw(),
        Ok(Err(error)) => {
            set_last_error(error);
            std::ptr::null_mut()
        }
        Err(_) => {
            set_last_error(ReadOfficeError::Panic);
            std::ptr::null_mut()
        }
    }
}

/// Takes the diagnostic produced by the most recent failed call on this thread, or NULL.
///
/// The returned UTF-8 string is owned by this library and must be passed to
/// `fastdoc_string_free`. Taking clears the slot, so stale failures cannot be mistaken for the
/// result of a later call.
#[no_mangle]
pub extern "C" fn fastdoc_take_last_error() -> *mut c_char {
    LAST_ERROR.with(|slot| {
        slot.borrow_mut()
            .take()
            .map_or(std::ptr::null_mut(), CString::into_raw)
    })
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
            "docx" | "docm" | "dotx" | "dotm" => {
                DocxReader::document_default_body_font_size(&archive)
            }
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
fn read_office(data: &[u8], extension: &str) -> Result<OfficeReadResult, ReadOfficeError> {
    // HWP is answered BEFORE the archive is opened, not after. `.hwp` is CFB binary rather than a
    // zip, so opening one as an archive fails and the reader would never be reached — which is how
    // the host's own dispatch does it too (`DocumentTypes.isHwp` branches ahead of `ZipArchive`).
    if matches!(extension.to_lowercase().as_str(), "hwp" | "hwpx") {
        return HwpReader::read_before_host_font_substitution(&swiftshim::Data::fromBytes(
            data.to_vec(),
        ))
        .map_err(ReadOfficeError::Hwp);
    }
    let archive = ZipArchive::new(swiftshim::Data::fromBytes(data.to_vec()))
        .map_err(|_| ReadOfficeError::InvalidArchive)?;
    match extension.to_lowercase().as_str() {
        "docx" | "docm" | "dotx" | "dotm" => {
            DocxReader::read(&archive).map_err(|error| ReadOfficeError::Reader(error.to_string()))
        }
        "odt" => {
            OdtReader::read(&archive).map_err(|error| ReadOfficeError::Reader(format!("{error:?}")))
        }
        other => Err(ReadOfficeError::UnsupportedExtension(other.to_owned())),
    }
}

fn extract(data: &[u8], extension: &str) -> Option<String> {
    let result = read_office(data, extension).ok()?;
    Some(OfficeMarkdownSerializer::serialize(
        &result.blocks,
        &result.footnotes,
    ))
}

/// Declares the font world this process runs in, answered by the HOST.
///
/// The engine cannot answer "is there a font called 함초롬바탕 on this machine", and it must not
/// guess: a provider that says every font exists never substitutes, one that says none does
/// substitutes everything, and both render a plausible document in the wrong typefaces with
/// nothing reporting it. So this is required before any office document is read, and reading one
/// without it panics rather than proceeding.
///
/// Call once. A second call is ignored rather than swapped — two halves of one document resolving
/// against different font worlds is worse than either world.
///
/// # Safety
/// The four function pointers must remain valid for the life of the process, and must be safe to
/// call from any thread. `face_named`'s argument is a NUL-terminated UTF-8 string; `describe`'s
/// out-parameters point at buffers of the stated capacities.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_install_font_provider(
    callbacks: swiftshim::font_provider::FontProviderCallbacks,
) -> bool {
    swiftshim::font_provider::install_callbacks(callbacks)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hwp_parse_failure_keeps_its_error_kind() {
        let error = read_office(b"not an HWP document", "hwp").unwrap_err();
        assert!(matches!(
            error,
            ReadOfficeError::Hwp(
                fastdoc_engine::render::office::hwp_reader::mapping::MapError::ParseFailed
            )
        ));
    }

    #[test]
    fn ffi_failure_diagnostic_is_owned_and_taken_once() {
        let extension = CString::new("hwp").unwrap();
        let data = b"not an HWP document";

        // SAFETY: Both pointers remain valid for the duration of the call. `extension` is
        // NUL-terminated and `data` is readable for exactly `data.len()` bytes.
        let result =
            unsafe { fastdoc_read_office_json(data.as_ptr(), data.len(), extension.as_ptr()) };
        assert!(result.is_null());

        let diagnostic = fastdoc_take_last_error();
        assert!(!diagnostic.is_null());
        // SAFETY: `diagnostic` came from this library, is NUL-terminated, and is not freed until
        // after this borrow ends.
        let message = unsafe { CStr::from_ptr(diagnostic) }
            .to_str()
            .unwrap()
            .to_owned();
        assert!(message.contains("HWP reader failed"), "{message}");
        // SAFETY: The pointer came from this library and has not previously been freed.
        unsafe { fastdoc_string_free(diagnostic) };
        assert!(fastdoc_take_last_error().is_null());
    }
}
