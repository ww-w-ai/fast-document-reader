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
//!
//! ## Ownership (S2B-05) — the single statement of the rule; every export above follows it
//!
//! 1. **Rust allocates every returned buffer.** Every `*mut c_char` this crate hands back —
//!    `fastdoc_extract_markdown`, `fastdoc_read_office_json`, `fastdoc_read_office_tree`,
//!    `fastdoc_take_last_error` — is a `CString::into_raw()` this library produced. The caller
//!    frees it with `fastdoc_string_free`, never with `free()` or its own allocator; the two
//!    allocators are not required to be interchangeable and are not assumed to be.
//! 2. **A failure is a value, not an exemption.** `fastdoc_read_office_tree`'s error envelope
//!    (`{"ffiVersion":1,"error":{...}}`) is exactly as owned as its ok envelope and must be freed
//!    the same way — this export never returns NULL for a document-level failure specifically so
//!    that both shapes go through one ownership rule instead of two.
//! 3. **NULL means nothing was allocated.** The only NULL a caller can receive is "the envelope
//!    itself could not be built" (`fastdoc_read_office_tree`) or "there is nothing to report"
//!    (`fastdoc_extract_markdown`, `fastdoc_read_office_json`, `fastdoc_take_last_error`). In
//!    every such case the caller owns nothing and must not call `fastdoc_string_free` on it —
//!    though doing so is harmless, see 4.
//! 4. **`fastdoc_string_free(NULL)` is a no-op.** Never undefined behaviour. A caller that frees
//!    defensively (without branching on NULL first) is safe.
//!
//! **Double-freeing a pointer this library returned, or reading it after it has been freed, is
//! undefined behaviour** — not a documented failure mode with a discriminated kind, because there
//! is no C ABI shape that reports UB after the fact. `tests/ffi_ownership.rs` proves 1-4 by
//! running them; it deliberately does NOT contain a double-free or use-after-free test, since
//! "running" UB is not a check, it is a second bug standing in for the first one.

mod ffi_guard;

use fastdoc_engine::render::office::hwp_reader::mapping::HwpReader;
use fastdoc_engine::render::office::{
    docx_reader::DocxReader, odt_reader::OdtReader, office_block::OfficeReadResult,
    office_markdown_serializer::OfficeMarkdownSerializer, zip_archive::ZipArchive,
};
use fastdoc_engine::render::render_tree::{DocumentFormat, OfficeAdapterInput, ValidatedRenderTree};
use ffi_guard::{guard_envelope, guard_json, guard_scalar, FfiErrorKind, FfiFailure};
use std::collections::BTreeMap;
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
        }
    }
}

impl ReadOfficeError {
    fn kind(&self) -> FfiErrorKind {
        match self {
            Self::InvalidArchive => FfiErrorKind::InvalidArchive,
            Self::UnsupportedExtension(_) => FfiErrorKind::UnsupportedExtension,
            Self::Hwp(_) => FfiErrorKind::HwpReadFailed,
            Self::Reader(_) => FfiErrorKind::ReaderFailed,
            Self::Export(_) => FfiErrorKind::ExportFailed,
        }
    }
}

impl From<ReadOfficeError> for FfiFailure {
    fn from(error: ReadOfficeError) -> Self {
        FfiFailure::new(error.kind(), error.to_string())
    }
}

/// `font_provider::try_provider`'s typed absence, discriminated for a host that will branch on
/// `kind` rather than parse prose. No export in this crate calls `try_provider` yet — S4/S5 make
/// the font-substitution path reachable from a guarded export, and this conversion is what that
/// export's guard closure will use with a plain `?`.
impl From<swiftshim::font_provider::FontProviderMissing> for FfiFailure {
    fn from(error: swiftshim::font_provider::FontProviderMissing) -> Self {
        FfiFailure::new(FfiErrorKind::HostFontProviderMissing, error.to_string())
    }
}

/// Records a guard's discriminated failure where `fastdoc_take_last_error` retrieves it. The
/// slot is deliberately last-write-wins (see `ffi_guard::contain`'s doc comment) — a re-entrant
/// call overwriting it is the existing, pre-S2B contract, not a bug this sprint fixes.
fn set_last_error(failure: &FfiFailure) {
    // CString can fail only when a diagnostic contains NUL. Replacing it keeps the failure
    // observable instead of recursively losing the error while trying to report it.
    let message = CString::new(failure.to_last_error_json()).unwrap_or_else(|_| {
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
/// NULL means the document could not be read. The return shape does NOT distinguish why: the
/// caller that needs a reason is the CLI, which does its own reading, and a reason string
/// crossing here would have to be freed on a path the caller takes only on failure — the shape
/// most likely to leak. A failure IS recorded for `fastdoc_take_last_error` now (S2B parity with
/// `fastdoc_read_office_json`), so a caller that wants a diagnostic for its own logs may still
/// take one; nothing about the NULL contract changes.
///
/// # Safety
/// `bytes` must point to `len` readable bytes and `extension_` must be a NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_extract_markdown(
    bytes: *const u8,
    len: usize,
    extension_: *const c_char,
) -> *mut c_char {
    clear_last_error();
    if bytes.is_null() || extension_.is_null() {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument",
        ));
        return std::ptr::null_mut();
    }
    let data = std::slice::from_raw_parts(bytes, len);
    let Ok(extension) = CStr::from_ptr(extension_).to_str() else {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "extension is not valid UTF-8",
        ));
        return std::ptr::null_mut();
    };

    // A panic must not cross the ABI — unwinding into Swift's frames is undefined behaviour, and
    // this engine still has `todo!()`s in reach of some documents. `guard_json` turns "the host
    // dies with no message" into "this document could not be read, and here is why", which is a
    // truth the host can act on.
    guard_json(move || {
        extract(data, extension).ok_or_else(|| {
            FfiFailure::new(
                FfiErrorKind::ReaderFailed,
                "the office reader produced no markdown for this document",
            )
        })
    })
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
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument",
        ));
        return std::ptr::null_mut();
    }
    let data = std::slice::from_raw_parts(bytes, len);
    let Ok(extension) = CStr::from_ptr(extension_).to_str() else {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "extension is not valid UTF-8",
        ));
        return std::ptr::null_mut();
    };
    // `guard_json` owns turning an interior NUL in `json` into `FfiErrorKind::InteriorNul` —
    // this closure just has to produce the string.
    guard_json(move || {
        let result = read_office(data, extension).map_err(FfiFailure::from)?;
        fastdoc_engine::render::office::office_export::to_json(&result).map_err(|error| {
            FfiFailure::from(ReadOfficeError::Export(format!("{error:?}")))
        })
    })
}

/// Reads an office document into the canonical `ValidatedRenderTree` wire form (S2B-03) and
/// returns it as a self-describing envelope — never NULL for a document-level failure, unlike
/// `fastdoc_extract_markdown`/`fastdoc_read_office_json` above:
///
/// - success: `{"ffiVersion":1,"ok":<the tree's own `encode_json()` bytes, spliced in verbatim>}`
/// - failure: `{"ffiVersion":1,"error":{"kind":"...","message":"...","location":"file:line:col"}}`
///
/// `ffiVersion` versions this envelope; `ok`'s `schemaVersion` (inside the tree JSON) versions the
/// tree — the two never mean the same thing, and neither call site should conflate them.
///
/// Ownership: the returned string is owned by this library in BOTH shapes and must be passed to
/// `fastdoc_string_free` either way — including the error envelope, which is not a `NULL`-style
/// sentinel here. NULL comes back ONLY when the envelope itself could not be allocated (its JSON
/// text was somehow not valid UTF-8, or contained an interior NUL); in that one case there is
/// nothing for the caller to own or free. This export does not touch `fastdoc_take_last_error`'s
/// slot — the envelope IS the diagnostic channel.
///
/// # Safety
/// `bytes` must point to `len` readable bytes and `extension_` must be a NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_read_office_tree(
    bytes: *const u8,
    len: usize,
    extension_: *const c_char,
) -> *mut c_char {
    if bytes.is_null() || extension_.is_null() {
        return guard_envelope(|| {
            Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "invalid NULL argument",
            ))
        });
    }
    let data = std::slice::from_raw_parts(bytes, len);
    let Ok(extension) = CStr::from_ptr(extension_).to_str() else {
        return guard_envelope(|| {
            Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "extension is not valid UTF-8",
            ))
        });
    };

    guard_envelope(move || {
        let format = document_format(extension).map_err(FfiFailure::from)?;
        let result = read_office(data, extension).map_err(FfiFailure::from)?;
        let source_name = format!("document.{extension}");
        let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
            format,
            source_name: &source_name,
            source_bytes: data,
            result: &result,
            resources: BTreeMap::new(),
        })
        .map_err(|error| FfiFailure::new(FfiErrorKind::ExportFailed, format!("{error:?}")))?;
        tree.encode_json()
            .map_err(|error| FfiFailure::new(FfiErrorKind::ExportFailed, format!("{error:?}")))
    })
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
    guard_scalar(DECLARED_NOTHING, move || {
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

/// The `render_tree::DocumentFormat` an extension declares — the same four-way split
/// `read_office` above already dispatches on, kept separate because `from_office`'s
/// `OfficeAdapterInput.format` and `read_office`'s reader choice are two different questions that
/// happen to share one answer set (docm/dotx/dotm are all `DocumentFormat::Docx`, matching Word's
/// own single template-family reader).
fn document_format(extension: &str) -> Result<DocumentFormat, ReadOfficeError> {
    match extension.to_lowercase().as_str() {
        "docx" | "docm" | "dotx" | "dotm" => Ok(DocumentFormat::Docx),
        "odt" => Ok(DocumentFormat::Odt),
        "hwp" => Ok(DocumentFormat::Hwp),
        "hwpx" => Ok(DocumentFormat::Hwpx),
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
    // Guarded like every other export, not because installation is expected to panic, but because
    // "every export goes through one guard" is only checkable if it has no exceptions. `false` is
    // the documented failure answer here — it already means "not installed".
    guard_scalar(false, move || {
        swiftshim::font_provider::install_callbacks(callbacks)
    })
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

    /// S2B-06: the font-provider precondition crosses into `fastdoc-ffi`'s error vocabulary as
    /// `hostFontProviderMissing`, exercised with no provider installed rather than by wiring a
    /// real export to resolve fonts just to manufacture reachability.
    #[test]
    fn font_provider_missing_maps_to_its_own_kind() {
        // `dyn FontProvider` is not `Debug`, so `Result::unwrap_err` does not typecheck here.
        let error = match swiftshim::font_provider::try_provider() {
            Err(error) => error,
            Ok(_) => panic!("no provider was installed"),
        };
        let failure = FfiFailure::from(error);
        assert_eq!(failure.kind, FfiErrorKind::HostFontProviderMissing);
        assert_eq!(failure.kind.tag(), "hostFontProviderMissing");
        assert!(failure.message.contains("no FontProvider installed"));
    }

    /// The Design's sentence is "every export goes through one containment core". A sentence is not
    /// a check: the export that installs the font provider was added outside the guard and nothing
    /// noticed until a fresh reviewer read the Design beside the code. This walks THIS file and
    /// fails on any `#[no_mangle]` export whose body names no guard.
    ///
    /// Two exports are exempt, and the exemption is stated rather than discovered:
    /// `fastdoc_take_last_error` and `fastdoc_string_free` are memory and thread-local plumbing that
    /// runs AFTER a failure has already been decided. Wrapping a deallocation in a panic guard buys
    /// nothing — there is no value left to return and nowhere to record the failure that the caller
    /// would still be able to read.
    #[test]
    fn every_export_but_the_two_named_plumbing_ones_goes_through_a_guard() {
        const EXEMPT: [&str; 2] = ["fastdoc_take_last_error", "fastdoc_string_free"];
        let source = include_str!("lib.rs");
        let mut unguarded = Vec::new();
        for part in source.split("#[no_mangle]").skip(1) {
            let Some(name_at) = part.find("fn fastdoc_") else {
                continue;
            };
            let rest = &part[name_at + 3..];
            let name: String = rest
                .chars()
                .take_while(|c| c.is_alphanumeric() || *c == '_')
                .collect();
            if EXEMPT.contains(&name.as_str()) {
                continue;
            }
            let body = part.split("\n}\n").next().unwrap_or(part);
            let guarded = ["guard_json", "guard_scalar", "guard_envelope"]
                .iter()
                .any(|g| body.contains(g));
            if !guarded {
                unguarded.push(name);
            }
        }
        assert!(
            unguarded.is_empty(),
            "these exports reach the ABI without the containment core: {unguarded:?}"
        );
    }
}
