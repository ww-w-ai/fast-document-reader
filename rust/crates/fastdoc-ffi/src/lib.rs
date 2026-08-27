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
    docx_reader::DocxReader, odt_reader::OdtReader, office_block::HeaderFooterApplicability,
    office_block::OfficeReadResult, office_markdown_serializer::OfficeMarkdownSerializer,
    master_page_selection::{select_master_templates, MasterPageQuery, MasterTemplateDescriptor},
    office_project, projection_ledger, zip_archive::ZipArchive,
};
use fastdoc_engine::render::render_tree::{DocumentFormat, OfficeAdapterInput, ValidatedRenderTree};
use ffi_guard::{guard_envelope, guard_json, guard_scalar, FfiErrorKind, FfiFailure};
use swiftshim::CGFloat;
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

/// `text_measure::try_measurer`'s typed absence — the same conversion as the font provider's,
/// for the same reason (S5-02).
impl From<swiftshim::text_measure::TextMeasurerMissing> for FfiFailure {
    fn from(error: swiftshim::text_measure::TextMeasurerMissing) -> Self {
        FfiFailure::new(FfiErrorKind::HostTextMeasurerMissing, error.to_string())
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
/// S4-07: the bytes this export returns now come from `ValidatedRenderTree::from_office` →
/// `office_project::project` FIRST — the tree path, proven equal to the reader path over the
/// registered fixtures by S4-02's oracle. Only when a document cannot cross the tree (a refusal
/// at either stage) does this fall back to the reader's own
/// `office_export::to_json(&OfficeReadResult)`, exactly as it returned before this sprint. The
/// fallback is never silent: `projection_ledger::record` names the document and the refusal kind
/// before the reader path runs, so S4-05's ledger and S4-03's census can be cross-checked against
/// each other. The return SHAPE — a bare JSON string, NULL on genuine failure — is unchanged: a
/// host reading this export cannot tell which branch produced its bytes, by design (that is what
/// "one door" means for S4-07).
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
        let source_name = format!("document.{extension}");
        project_or_fall_back(extension, &source_name, data, &result)
    })
}

/// The pipeline S4-07's design names: `from_office` → `project` on success, a recorded fallback to
/// `to_json(&result)` on either stage's refusal. Split out of `fastdoc_read_office_json` so the
/// two failure directions this sprint must not change — "already worked, still works" and
/// "already failed, still fails the same way" — are each one `match` arm, not entangled in the
/// unsafe FFI wrapper.
fn project_or_fall_back(
    extension: &str,
    source_name: &str,
    source_bytes: &[u8],
    result: &OfficeReadResult,
) -> Result<String, FfiFailure> {
    let format = document_format(extension).map_err(FfiFailure::from)?;
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format,
        source_name,
        source_bytes,
        result,
        resources: BTreeMap::new(),
    });
    match tree {
        Ok(tree) => match office_project::project(&tree) {
            Ok(projected) => Ok(projected),
            Err(error) => {
                projection_ledger::record(
                    source_name,
                    projection_ledger::projection_error_kind(&error),
                    error.description(),
                );
                fall_back_to_reader(result)
            }
        },
        Err(error) => {
            projection_ledger::record(
                source_name,
                projection_ledger::adapter_error_kind(&error),
                format!("{error:?}"),
            );
            fall_back_to_reader(result)
        }
    }
}

/// The unchanged path: `office_export::to_json(&OfficeReadResult)`, exactly as
/// `fastdoc_read_office_json` called it before S4-07 — this function exists only so the fallback
/// is spelled once, from both refusal sites above.
fn fall_back_to_reader(result: &OfficeReadResult) -> Result<String, FfiFailure> {
    fastdoc_engine::render::office::office_export::to_json(result)
        .map_err(|error| FfiFailure::from(ReadOfficeError::Export(format!("{error:?}"))))
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
/// The running header (or footer) band height for a document, decided in the engine and measured
/// through the host's installed text measurer.
///
/// Returns a NEGATIVE sentinel when it cannot answer — no measurer installed, the document
/// unreadable, or a band carrying something whose size the engine does not know. A height is never
/// negative, so the sentinel cannot be mistaken for an answer, and `fastdoc_take_last_error` names
/// which case it was. Same shape as `fastdoc_office_default_body_font_size`: a scalar return has
/// nowhere to put an envelope, so the failure goes where the existing contract already says to look.
///
/// # Safety
/// `bytes`/`len` describe a readable buffer for the duration of the call, and `extension` is a
/// NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_office_header_band_height(
    bytes: *const u8,
    len: usize,
    extension_: *const c_char,
    column_width: f64,
    footer: bool,
) -> f64 {
    const CANNOT_ANSWER: f64 = -1.0;
    clear_last_error();
    if bytes.is_null() || extension_.is_null() {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument",
        ));
        return CANNOT_ANSWER;
    }
    let data = std::slice::from_raw_parts(bytes, len);
    let Ok(extension) = CStr::from_ptr(extension_).to_str() else {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "extension is not valid UTF-8",
        ));
        return CANNOT_ANSWER;
    };
    guard_scalar(CANNOT_ANSWER, move || {
        let result = match read_office(data, extension) {
            Ok(result) => result,
            Err(error) => {
                set_last_error(&FfiFailure::from(error));
                return CANNOT_ANSWER;
            }
        };
        let theme = fastdoc_engine::render::render_theme::RenderTheme::current(result.default_body_font_size);
        let empty: Vec<fastdoc_engine::render::office::office_block::OfficeHeaderFooter> = Vec::new();
        let (headers, footers) = if footer {
            (empty.as_slice(), result.footers.as_slice())
        } else {
            (result.headers.as_slice(), empty.as_slice())
        };
        match fastdoc_engine::render::office::page_band_geometry::PageBandGeometry::band_height(
            headers,
            footers,
            &theme,
            column_width,
            result.default_body_font_size,
            None,
            None,
            None,
        ) {
            Ok(height) => height,
            Err(error) => {
                set_last_error(&FfiFailure::new(
                    FfiErrorKind::HostTextMeasurerMissing,
                    format!("{error}"),
                ));
                CANNOT_ANSWER
            }
        }
    })
}

/// S5C1-01: an opaque document handle — the export above re-reads the document from bytes on
/// EVERY call (2.4s for a debug parse of a 10.2MB HWP, measured), and the three sprints after this
/// one (S5C-2 sheet placement, S5C-3 the 바탕쪽, S5D the footnote band) each need "the document you
/// already read" too. This is the one place that cost gets paid: once, at open.
///
/// Boxed and returned as a raw pointer (`Box::into_raw`); `fastdoc_office_close` takes it back
/// with `Box::from_raw` and drops it. One owner, one close — the Swift side holds this in the
/// object that owns the document's lifetime (`MarkdownDocument`) and closes it in `deinit`, never
/// in a `defer` at a call site, so a reload (close-then-reopen) can never strand or double-free it.
pub struct FastdocOfficeDocument {
    result: OfficeReadResult,
}

/// Reads an office document ONCE and hands back an opaque handle every later query borrows,
/// rather than re-reading it. Returns NULL and records the failure through
/// `fastdoc_take_last_error` when the document cannot be read — the SAME `read_office` failure
/// this file's other exports already report, not a new refusal shape.
///
/// # Safety
/// `bytes`/`len` describe a readable buffer for the duration of this call only (the handle copies
/// what it needs and does not borrow the caller's buffer afterward), and `extension_` is a
/// NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_office_open(
    bytes: *const u8,
    len: usize,
    extension_: *const c_char,
) -> *mut FastdocOfficeDocument {
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
    guard_scalar(std::ptr::null_mut(), move || {
        match read_office(data, extension) {
            Ok(result) => Box::into_raw(Box::new(FastdocOfficeDocument { result })),
            Err(error) => {
                set_last_error(&FfiFailure::from(error));
                std::ptr::null_mut()
            }
        }
    })
}

/// Closes a handle `fastdoc_office_open` returned. NULL is a no-op, matching this crate's existing
/// string-ownership rule (`fastdoc_string_free(NULL)`). Closing a handle twice, or querying one
/// after it is closed, is undefined behaviour — the same statement this file's module doc already
/// makes for a double-freed string, extended to this second owned resource.
///
/// # Safety
/// `handle` must be either NULL or a pointer this crate's `fastdoc_office_open` returned and that
/// has not already been passed to this function.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_office_close(handle: *mut FastdocOfficeDocument) {
    guard_scalar((), move || {
        if !handle.is_null() {
            drop(Box::from_raw(handle));
        }
    })
}

/// The band query re-expressed over an open handle (S5C1-02): the engine's own decision for a
/// document's running header, footer AND combined band, in one call, from a document it already
/// holds rather than one it re-reads.
///
/// The three page values are OPTIONAL in the same sense the host's own `PageBandGeometry` treats
/// them — each carries an explicit `has_*` flag rather than a sentinel folded into the value
/// itself, so a value the host actually passed can never be confused with one it did not (fact 2
/// of this unit's plan: a `None` silently substituted for a stated margin answers a different
/// question than the live path asks). `headers_on`/`footers_on` mirror the host's own
/// `PageViewOptions` — a toggle switched off is passed through as NO ENTRIES, exactly as the
/// host's `applyPageBand` already does it, so "hidden" means the same thing on both sides of the
/// FFI.
///
/// Fills `out[0..3]` (header, footer, band) and returns `true`, or leaves `out` untouched and
/// returns `false` — no measurer installed, the band carrying something the engine cannot resolve,
/// or a NULL handle/out pointer — with `fastdoc_take_last_error` naming which. A refusal here is
/// the safe direction: the host falls back to its own answer rather than draw a bandless page.
///
/// # Safety
/// `handle` must be either NULL or a live pointer `fastdoc_office_open` returned that has not been
/// closed. `out` must describe a writable buffer of at least 3 `f64`s for the duration of the
/// call.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fastdoc_office_band_sides(
    handle: *const FastdocOfficeDocument,
    column_width: f64,
    page_content_width: f64,
    has_page_content_width: bool,
    page_margin_top: f64,
    has_page_margin_top: bool,
    page_margin_bottom: f64,
    has_page_margin_bottom: bool,
    headers_on: bool,
    footers_on: bool,
    separates_pages: bool,
    desk_gap: f64,
    has_desk_gap: bool,
    out: *mut f64,
) -> bool {
    clear_last_error();
    if handle.is_null() || out.is_null() {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument",
        ));
        return false;
    }
    let handle_ref: &FastdocOfficeDocument = &*handle;
    let page_content_width = has_page_content_width.then_some(page_content_width);
    let page_margin_top = has_page_margin_top.then_some(page_margin_top);
    let page_margin_bottom = has_page_margin_bottom.then_some(page_margin_bottom);
    let desk_gap = has_desk_gap.then_some(desk_gap);
    let sides: Option<[f64; 3]> = guard_scalar(None, move || {
        let result = &handle_ref.result;
        let theme = fastdoc_engine::render::render_theme::RenderTheme::current(result.default_body_font_size);
        let empty: Vec<fastdoc_engine::render::office::office_block::OfficeHeaderFooter> = Vec::new();
        let headers = if headers_on { result.headers.as_slice() } else { empty.as_slice() };
        let footers = if footers_on { result.footers.as_slice() } else { empty.as_slice() };
        match fastdoc_engine::render::office::page_band_geometry::PageBandGeometry::measure(
            headers,
            footers,
            &theme,
            column_width,
            result.default_body_font_size,
            page_content_width,
            page_margin_top,
            page_margin_bottom,
            separates_pages,
            desk_gap,
        ) {
            Ok(sides) => Some([sides.header, sides.footer, sides.band]),
            Err(error) => {
                set_last_error(&FfiFailure::new(
                    FfiErrorKind::HostTextMeasurerMissing,
                    format!("{error}"),
                ));
                None
            }
        }
    });
    match sides {
        Some(values) => {
            let out_slice = std::slice::from_raw_parts_mut(out, 3);
            out_slice.copy_from_slice(&values);
            true
        }
        None => false,
    }
}

/// S5C2-01: every SHEET a paged document prints as, from the scalars `printSheets` already
/// resolves (`page_pagination::PagePagination::sheets`'s own doc explains why `pitch` and
/// `top_margin` are not crossed separately — they are scalar addition/`max`, and the divergence
/// invariant 59 guards against is never at risk from that arithmetic agreeing). `count` is the
/// host's own `printPageCount` (a LIVE layout answer, unavailable to the engine — the host still
/// decides how many pages there are).
///
/// Fills `out[0..count*4]` as `[x, y, width, height]` per sheet, in the SAME order
/// `PagePagination.sheets` returns them, and sets `*out_count` to the sheet count actually
/// written (`0` for a document that does not paginate, matching the host's own empty-array
/// answer). Returns `false` (`fastdoc_take_last_error` names it) when `out_capacity` is smaller
/// than `count * 4` — the host must size its buffer from the SAME `count` it passed in, which it
/// always knows ahead of the call.
///
/// # Safety
/// `handle` must be either NULL or a live pointer `fastdoc_office_open` returned that has not been
/// closed (unused beyond the NULL check — this arithmetic needs no document state, but the export
/// is shaped over the handle for consistency with this file's other S5C1/S5C2 exports). `out` must
/// describe a writable buffer of at least `out_capacity` `f64`s, and `out_count` a writable
/// `usize`, both for the duration of the call.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fastdoc_office_sheets(
    handle: *const FastdocOfficeDocument,
    count: i64,
    width: f64,
    text_origin_y: f64,
    leading_band: f64,
    pitch: f64,
    top_margin: f64,
    desk_gap: f64,
    out: *mut f64,
    out_capacity: usize,
    out_count: *mut usize,
) -> bool {
    clear_last_error();
    if handle.is_null() || out.is_null() || out_count.is_null() {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument",
        ));
        return false;
    }
    let sheets: Vec<swiftshim::CGRect> = guard_scalar(Vec::new(), move || {
        fastdoc_engine::render::office::page_pagination::PagePagination::sheets(
            count, width, text_origin_y, leading_band, pitch, top_margin, desk_gap,
        )
    });
    let Some(needed) = sheets.len().checked_mul(4) else {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "sheet count overflowed the output buffer size",
        ));
        return false;
    };
    if needed > out_capacity {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "out buffer too small for the sheet count",
        ));
        return false;
    }
    if needed > 0 {
        let out_slice = std::slice::from_raw_parts_mut(out, needed);
        for (i, rect) in sheets.iter().enumerate() {
            out_slice[i * 4] = rect.minX();
            out_slice[i * 4 + 1] = rect.minY();
            out_slice[i * 4 + 2] = rect.width();
            out_slice[i * 4 + 3] = rect.height();
        }
    }
    *out_count = sheets.len();
    true
}

/// One laid-out ROW, mirroring `page_pagination::LaidOutRow` field for field —
/// `fastdoc_office_table_placement`'s flat `rows` array, sliced per table by `row_offset`/
/// `row_count`. `#[repr(C)]` so the layout is exactly what the header declares.
#[repr(C)]
pub struct FastdocLaidOutRow {
    pub first_char: i64,
    pub top: CGFloat,
    pub bottom: CGFloat,
    pub first_line_top: CGFloat,
    pub can_break_above: bool,
}

/// One laid-out TABLE, mirroring `page_pagination::LaidOutTable` except that `rows` is replaced by
/// an offset/count into `fastdoc_office_table_placement`'s flat `rows` array — the same
/// offset/count shape `FastdocTableResizeTableDesc` already uses for tables-then-cells. `#[repr(C)]`
/// so the layout is exactly what the header declares.
#[repr(C)]
pub struct FastdocLaidOutTable {
    pub first_char: i64,
    pub visual_top: CGFloat,
    pub bottom: CGFloat,
    pub first_line_top: CGFloat,
    pub last_char: i64,
    pub row_offset: usize,
    pub row_count: usize,
    pub keeps_whole: bool,
}

/// One `first_char -> (height, top_inset)` entry, mirroring `page_pagination::TableMetrics` keyed
/// by the character it belongs to — the wire shape both `already_pushed`'s input and
/// `tables_to_push`'s output use, so one struct serves both directions. `#[repr(C)]` so the layout
/// is exactly what the header declares.
#[repr(C)]
pub struct FastdocTableMetricsEntry {
    pub key: i64,
    pub height: CGFloat,
    pub top_inset: CGFloat,
}

/// One `page -> height` entry — `note_bands`'s wire shape. The host SORTS this array by `page`
/// before crossing (S5C-2's own contract: an unordered `HashMap` crossing as a flat array could
/// answer differently between two runs of the same document if the engine's OWN map-building ever
/// depended on encounter order, which `tables_to_push`/`oversized_pieces` do not — but the contract
/// is stated here rather than left to be true only because nothing currently exploits it).
/// `#[repr(C)]` so the layout is exactly what the header declares.
#[repr(C)]
pub struct FastdocNoteBandEntry {
    pub page: i64,
    pub value: CGFloat,
}

/// One `first_char -> last_char` entry — `already_oversized`'s wire shape (input) and
/// `oversized_pieces`'s wire shape (output). `#[repr(C)]` so the layout is exactly what the header
/// declares.
#[repr(C)]
pub struct FastdocI64Entry {
    pub key: i64,
    pub value: i64,
}

/// S5C2-01: which tables must move whole to the next page (`tables_to_push`) and which pieces fit
/// on no page at all (`oversized_pieces`), from a completed layout — `settlePagedTables`'s whole
/// arithmetic half, over the S5C-1 handle for consistency with this file's other exports (unused
/// beyond the NULL check; both Rust functions are pure and need no document state, since every
/// fact they need is already IN the laid-out tables and rows the host walked).
///
/// `joining_unopened_boundaries` is NOT answered here. It has exactly one caller, `pageSheets`,
/// and S5C-2's own contract leaves `pageSheets` deriving from `printSheets` untouched — exporting
/// an FFI surface with no wiring to call it would reproduce, on a smaller scale, the zero-caller
/// state this sprint exists to fix on `tables_to_push`/`oversized_pieces`/`sheets` themselves. The
/// pure Rust function remains available in `page_pagination.rs` for the sprint that DOES move
/// `pageSheets`.
///
/// `tables`/`rows` are the host's `laidOutTables()` walk, flattened: each table names its own
/// slice of `rows` by `row_offset`/`row_count`, exactly as `FastdocTableResizeTableDesc` names its
/// slice of `cells`. `already_pushed`/`note_bands`/`already_oversized` are the settle loop's
/// carried state, each a flat array of entries (the host may pass them in any order — the engine
/// builds a `HashMap` from them and neither `tables_to_push` nor `oversized_pieces` reads that map
/// in iteration order, only by key lookup).
///
/// Fills `out_push`/`out_oversized` — each SORTED BY KEY, so two runs over the same document answer
/// identically regardless of Rust's own randomized `HashMap` iteration order — and sets
/// `*out_push_count`/`*out_oversized_count` to the number of entries actually written. Returns
/// `false` (`fastdoc_take_last_error` names it) when either output buffer is smaller than the
/// engine's own answer needs, when a table descriptor's `row_offset`/`row_count` runs past the flat
/// `rows` buffer, or on a NULL handle/required pointer. A safe upper bound for both output
/// capacities is `table_count + row_count` — `tables_to_push` registers at most one entry per
/// unbreakable group (at most one per row) plus the already-carried keys, and `oversized_pieces`
/// the same; a caller that does not want to reason about the exact bound may simply pass that sum.
///
/// # Safety
/// `handle` must be either NULL or a live pointer `fastdoc_office_open` returned that has not been
/// closed. `tables`/`table_count`, `rows`/`row_count`, `already_pushed`/`already_pushed_count`,
/// `note_bands`/`note_bands_count` and `already_oversized`/`already_oversized_count` describe
/// readable buffers for the duration of the call. `out_push`/`out_push_capacity`,
/// `out_push_count`, `out_oversized`/`out_oversized_capacity` and `out_oversized_count` describe
/// writable buffers/scalars for the duration of the call.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fastdoc_office_table_placement(
    handle: *const FastdocOfficeDocument,
    tables: *const FastdocLaidOutTable,
    table_count: usize,
    rows: *const FastdocLaidOutRow,
    row_count: usize,
    page_content_height: f64,
    band: f64,
    leading_band: f64,
    split_tables: bool,
    already_pushed: *const FastdocTableMetricsEntry,
    already_pushed_count: usize,
    note_bands: *const FastdocNoteBandEntry,
    note_bands_count: usize,
    already_oversized: *const FastdocI64Entry,
    already_oversized_count: usize,
    out_push: *mut FastdocTableMetricsEntry,
    out_push_capacity: usize,
    out_push_count: *mut usize,
    out_oversized: *mut FastdocI64Entry,
    out_oversized_capacity: usize,
    out_oversized_count: *mut usize,
) -> bool {
    use fastdoc_engine::render::office::page_pagination::{
        LaidOutRow, LaidOutTable, PagePagination, TableMetrics,
    };

    clear_last_error();
    if handle.is_null()
        || (table_count > 0 && tables.is_null())
        || (row_count > 0 && rows.is_null())
        || (already_pushed_count > 0 && already_pushed.is_null())
        || (note_bands_count > 0 && note_bands.is_null())
        || (already_oversized_count > 0 && already_oversized.is_null())
        || out_push_count.is_null()
        || out_oversized_count.is_null()
    {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument",
        ));
        return false;
    }

    let table_descs: &[FastdocLaidOutTable] = if table_count == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(tables, table_count)
    };
    let flat_rows: &[FastdocLaidOutRow] = if row_count == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(rows, row_count)
    };

    let mut laid_out_tables: Vec<LaidOutTable> = Vec::with_capacity(table_descs.len());
    for t in table_descs {
        let row_end = t.row_offset.checked_add(t.row_count);
        let table_rows: Vec<LaidOutRow> = match row_end {
            Some(row_end) if row_end <= flat_rows.len() => flat_rows[t.row_offset..row_end]
                .iter()
                .map(|r| LaidOutRow::new(r.first_char, r.top, r.bottom, r.first_line_top, r.can_break_above))
                .collect(),
            _ => {
                set_last_error(&FfiFailure::new(
                    FfiErrorKind::InvalidArgument,
                    "a table descriptor's row_offset/row_count runs past the flat rows buffer",
                ));
                return false;
            }
        };
        laid_out_tables.push(LaidOutTable::new(
            t.first_char,
            t.visual_top,
            t.bottom,
            t.first_line_top,
            Some(t.last_char),
            table_rows,
            t.keeps_whole,
        ));
    }

    let already_pushed_map: std::collections::HashMap<i64, TableMetrics> = if already_pushed_count
        == 0
    {
        std::collections::HashMap::new()
    } else {
        std::slice::from_raw_parts(already_pushed, already_pushed_count)
            .iter()
            .map(|e| (e.key, TableMetrics::new(e.height, e.top_inset)))
            .collect()
    };
    let note_bands_map: std::collections::HashMap<i64, CGFloat> = if note_bands_count == 0 {
        std::collections::HashMap::new()
    } else {
        std::slice::from_raw_parts(note_bands, note_bands_count)
            .iter()
            .map(|e| (e.page, e.value))
            .collect()
    };
    let already_oversized_map: std::collections::HashMap<i64, i64> = if already_oversized_count
        == 0
    {
        std::collections::HashMap::new()
    } else {
        std::slice::from_raw_parts(already_oversized, already_oversized_count)
            .iter()
            .map(|e| (e.key, e.value))
            .collect()
    };

    let (mut pushed, mut oversized): (Vec<(i64, TableMetrics)>, Vec<(i64, i64)>) = guard_scalar(
        (Vec::new(), Vec::new()),
        move || {
            let pushed = PagePagination::tables_to_push(
                &laid_out_tables,
                page_content_height,
                band,
                leading_band,
                split_tables,
                &already_pushed_map,
                &note_bands_map,
            );
            let oversized = PagePagination::oversized_pieces(
                &laid_out_tables,
                page_content_height,
                band,
                leading_band,
                &note_bands_map,
                &already_oversized_map,
            );
            (pushed.into_iter().collect(), oversized.into_iter().collect())
        },
    );
    // SORTED BY KEY — the engine's `HashMap` iteration order is randomized per process, and this
    // is the seam that would otherwise let two runs of the same document answer differently.
    pushed.sort_by_key(|(k, _)| *k);
    oversized.sort_by_key(|(k, _)| *k);

    if pushed.len() > out_push_capacity || oversized.len() > out_oversized_capacity {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "out buffer too small for the answer",
        ));
        return false;
    }
    if !pushed.is_empty() {
        let out_slice = std::slice::from_raw_parts_mut(out_push, pushed.len());
        for (i, (key, metrics)) in pushed.iter().enumerate() {
            out_slice[i] = FastdocTableMetricsEntry {
                key: *key,
                height: metrics.height,
                top_inset: metrics.top_inset,
            };
        }
    }
    *out_push_count = pushed.len();
    if !oversized.is_empty() {
        let out_slice = std::slice::from_raw_parts_mut(out_oversized, oversized.len());
        for (i, (key, value)) in oversized.iter().enumerate() {
            out_slice[i] = FastdocI64Entry { key: *key, value: *value };
        }
    }
    *out_oversized_count = oversized.len();
    true
}

/// One cell's own geometry, mirroring `fastdoc_engine::render::table_resize_math::TableResizeCell`
/// field for field. `#[repr(C)]` so the layout is exactly what the header declares.
#[repr(C)]
pub struct FastdocTableResizeCell {
    pub starting_column: usize,
    pub column_span: usize,
    pub pad_left: CGFloat,
    pub pad_right: CGFloat,
    pub border_left: CGFloat,
    pub border_right: CGFloat,
}

/// S5B2a: the arithmetic behind `Render/TableBlockBuilder.swift`'s `resizeTables` — one call per
/// table, HOST TO RUST, the opposite direction from every other export on this page (S5's own
/// text-measurement port has Rust call a host-installed callback; here the host already holds the
/// live `NSTextStorage` and calls straight in). Fills `out_widths[0..cell_count]` with each
/// `cells[i]`'s target content width and returns `true`, or leaves `out_widths` untouched and
/// returns `false` on a bad payload — `fastdoc_take_last_error` names which.
///
/// `max_width <= 0.0` means "no authored cap", matching `edges(forWidth:)`'s own
/// `guard let maxWidth, maxWidth > 0 else { return width }` — a real authored cap is always a
/// positive point width, so the sentinel cannot collide with an answer.
///
/// Ownership is inverted from this file's other exports: `out_widths` is allocated and owned by
/// the CALLER (at least `cell_count` `CGFloat`s), lent for the duration of this call only. Nothing
/// here is allocated by this library, so there is no `fastdoc_*_free` counterpart.
///
/// # Safety
/// `column_proportions`/`column_count` and `cells`/`cell_count` describe readable buffers for the
/// duration of the call; `out_widths` describes a writable buffer of at least `cell_count`
/// `CGFloat`s for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_table_resize_cell_widths(
    column_proportions: *const CGFloat,
    column_count: usize,
    available_width: CGFloat,
    outer_margin_left: CGFloat,
    outer_margin_right: CGFloat,
    max_width: CGFloat,
    cells: *const FastdocTableResizeCell,
    cell_count: usize,
    out_widths: *mut CGFloat,
) -> bool {
    clear_last_error();
    if (column_count > 0 && column_proportions.is_null())
        || (cell_count > 0 && (cells.is_null() || out_widths.is_null()))
    {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument",
        ));
        return false;
    }
    // `slice::from_raw_parts` requires a non-NULL, aligned pointer even for a zero-length slice —
    // a NULL/0 pair is valid C (nothing to describe) but undefined Rust, so a zero count skips the
    // call entirely rather than handing `from_raw_parts` a NULL it would abort on.
    let column_proportions = if column_count == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(column_proportions, column_count).to_vec()
    };
    let cell_inputs: Vec<fastdoc_engine::render::table_resize_math::TableResizeCell> = if cell_count
        == 0
    {
        Vec::new()
    } else {
        std::slice::from_raw_parts(cells, cell_count)
            .iter()
            .map(|c| fastdoc_engine::render::table_resize_math::TableResizeCell {
                starting_column: c.starting_column,
                column_span: c.column_span,
                pad_left: c.pad_left,
                pad_right: c.pad_right,
                border_left: c.border_left,
                border_right: c.border_right,
            })
            .collect()
    };
    let input = fastdoc_engine::render::table_resize_math::TableResizeInput {
        column_proportions,
        available_width,
        outer_margin_left,
        outer_margin_right,
        max_width: if max_width > 0.0 { Some(max_width) } else { None },
        cells: cell_inputs,
    };
    let widths: Option<Vec<CGFloat>> = guard_scalar(None, move || {
        Some(fastdoc_engine::render::table_resize_math::cell_target_widths(&input))
    });
    match widths {
        Some(widths) if widths.len() == cell_count => {
            if cell_count > 0 {
                let out = std::slice::from_raw_parts_mut(out_widths, cell_count);
                out.copy_from_slice(&widths);
            }
            true
        }
        _ => {
            set_last_error(&FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "arithmetic failed or returned the wrong cell count",
            ));
            false
        }
    }
}

/// One table's shared-grid inputs plus where its slice sits in the two flat arrays below —
/// `fastdoc_table_resize_cell_widths_batch`'s per-table descriptor, mirroring
/// `fastdoc_engine::render::table_resize_math::TableResizeInput` field for field except that
/// `column_proportions`/`cells` are replaced by an offset/count into the caller's flat buffers.
/// `#[repr(C)]` so the layout is exactly what the header declares.
#[repr(C)]
pub struct FastdocTableResizeTableDesc {
    pub column_offset: usize,
    pub column_count: usize,
    pub available_width: CGFloat,
    pub outer_margin_left: CGFloat,
    pub outer_margin_right: CGFloat,
    pub max_width: CGFloat,
    pub cell_offset: usize,
    pub cell_count: usize,
}

/// `fastdoc_table_resize_cell_widths` above crosses the FFI boundary once PER TABLE. On a
/// 323-table, 6,077-cell document that path cost 9.5ms against the host's own 4.5ms, and the gap
/// decomposed into 0.35ms of boundary, 1.6ms of payload arrays and 2.4ms of collection — the
/// crossing count was the small share (`s5b2b-latency.md`). This export answers EVERY table in ONE
/// call: `tables[i]` names its own slice of the flat `column_proportions` and `cells` arrays by
/// offset/count, `out_widths` is filled in the SAME flattened table-then-cell order the caller
/// built the payload in, and the total `cell_count` (summed across every table) is what
/// `out_widths` must be sized to.
///
/// Does not replace the single-table export — `RustEngineTableResize`'s S5B2a parity test and any
/// caller that only ever has one table still reach that one; this is an ADDITIONAL door for the
/// production reflow path, which now has every table's payload in hand at once (`resizeTables`
/// collects all tables before asking the engine, exactly so it can call this once).
///
/// Each descriptor's `column_offset..column_offset+column_count` and
/// `cell_offset..cell_offset+cell_count` must fit within `column_proportions_count` and
/// `cell_count` respectively, or this returns `false` (`fastdoc_take_last_error` names it) rather
/// than reading past either buffer.
///
/// Ownership is inverted, same as the single-table export: `out_widths` is allocated and owned by
/// the CALLER (at least the SUM of every `tables[i].cell_count`), lent for the duration of this
/// call only.
///
/// # Safety
/// `tables`/`table_count`, `column_proportions`/`column_proportions_count` and
/// `cells`/`cell_count` describe readable buffers for the duration of the call; `out_widths`
/// describes a writable buffer of at least `cell_count` `CGFloat`s for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_table_resize_cell_widths_batch(
    tables: *const FastdocTableResizeTableDesc,
    table_count: usize,
    column_proportions: *const CGFloat,
    column_proportions_count: usize,
    cells: *const FastdocTableResizeCell,
    cell_count: usize,
    out_widths: *mut CGFloat,
) -> bool {
    clear_last_error();
    if (table_count > 0 && tables.is_null())
        || (column_proportions_count > 0 && column_proportions.is_null())
        || (cell_count > 0 && (cells.is_null() || out_widths.is_null()))
    {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument",
        ));
        return false;
    }
    // Same zero-length guard as the single-table export: `from_raw_parts` requires a non-NULL,
    // aligned pointer even for a zero-length slice.
    let table_descs: &[FastdocTableResizeTableDesc] = if table_count == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(tables, table_count)
    };
    let all_column_proportions: Vec<CGFloat> = if column_proportions_count == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(column_proportions, column_proportions_count).to_vec()
    };
    let all_cells: Vec<fastdoc_engine::render::table_resize_math::TableResizeCell> =
        if cell_count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(cells, cell_count)
                .iter()
                .map(|c| fastdoc_engine::render::table_resize_math::TableResizeCell {
                    starting_column: c.starting_column,
                    column_span: c.column_span,
                    pad_left: c.pad_left,
                    pad_right: c.pad_right,
                    border_left: c.border_left,
                    border_right: c.border_right,
                })
                .collect()
        };

    let mut inputs = Vec::with_capacity(table_descs.len());
    for desc in table_descs {
        let column_end = desc.column_offset.checked_add(desc.column_count);
        let cell_end = desc.cell_offset.checked_add(desc.cell_count);
        match (column_end, cell_end) {
            (Some(column_end), Some(cell_end))
                if column_end <= all_column_proportions.len() && cell_end <= all_cells.len() =>
            {
                inputs.push(fastdoc_engine::render::table_resize_math::TableResizeInput {
                    column_proportions: all_column_proportions[desc.column_offset..column_end]
                        .to_vec(),
                    available_width: desc.available_width,
                    outer_margin_left: desc.outer_margin_left,
                    outer_margin_right: desc.outer_margin_right,
                    max_width: if desc.max_width > 0.0 {
                        Some(desc.max_width)
                    } else {
                        None
                    },
                    cells: all_cells[desc.cell_offset..cell_end].to_vec(),
                });
            }
            _ => {
                set_last_error(&FfiFailure::new(
                    FfiErrorKind::InvalidArgument,
                    "a table descriptor's offset/count runs past its flat buffer",
                ));
                return false;
            }
        }
    }

    let widths: Option<Vec<CGFloat>> = guard_scalar(None, move || {
        Some(fastdoc_engine::render::table_resize_math::cell_target_widths_batch(&inputs))
    });
    match widths {
        Some(widths) if widths.len() == cell_count => {
            if cell_count > 0 {
                let out = std::slice::from_raw_parts_mut(out_widths, cell_count);
                out.copy_from_slice(&widths);
            }
            true
        }
        _ => {
            set_last_error(&FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "arithmetic failed or returned the wrong cell count",
            ));
            false
        }
    }
}

/// One master-page TEMPLATE descriptor — `(section, appliesTo)`, mirroring `OfficeMasterPage`'s
/// own two selection fields (`OfficeBlock.swift`). `#[repr(C)]` so the layout is exactly what the
/// header declares.
///
/// `applies_to` is `HeaderFooterApplicability`'s wire tag, the same three-way vocabulary a master
/// page shares with a running header/footer: `0` = `.defaultPages`, `1` = `.firstPage`, `2` =
/// `.evenPages`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct FastdocMasterTemplateDesc {
    pub section: i64,
    pub applies_to: i32,
}

/// One VISIBLE page's selection query — `(pageIndex, section?)`, mirroring
/// `MasterPagePainter.applicablePage`'s own two arguments beyond the template list. Position `i`
/// in the caller's array answers to `out_template_index[i]`. `has_section == false` matches
/// `applicablePage`'s own `nil` fallback: every template is a candidate, not none. `#[repr(C)]` so
/// the layout is exactly what the header declares.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct FastdocMasterPageQuery {
    pub page_index: i64,
    pub has_section: bool,
    pub section: i64,
}

/// `fastdoc_office_master_selection` — S5C3-01/03: `MasterPagePainter.applicablePage` plus the
/// section veto (`:73`), ported as a pure function (`office::master_page_selection`) and exposed
/// batched over every visible page in ONE call, the shape `s5c3.md`'s API section requires ("the
/// host's own loop is per page … one crossing per page at scroll frequency is the shape this plan
/// rejected"). Retires S5C3-06a, deleted in this same change.
///
/// **In:** `templates`/`template_count` — the document's own master-page descriptors, in the SAME
/// order the caller's array holds them (an output index below names a position in THAT array, not
/// a Rust-side reordering). `vetoed_sections`/`vetoed_section_count` — the section-veto set
/// (`MasterPageContent.sectionsHidingMasterPage`). `pages`/`page_count` — one entry per VISIBLE
/// sheet this draw pass is walking.
///
/// **Out:** `out_template_index[i]` is the applicable template's index into the caller's own
/// `templates` array for `pages[i]`, or `-1` for "no template applies" (no candidates for the
/// page's section, or the page's section is vetoed).
///
/// # Safety
/// `templates`/`template_count`, `vetoed_sections`/`vetoed_section_count` and `pages`/`page_count`
/// describe readable buffers for the duration of the call. `out_template_index` describes a
/// writable buffer of at least `page_count` `i64`s for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_office_master_selection(
    templates: *const FastdocMasterTemplateDesc,
    template_count: usize,
    vetoed_sections: *const i64,
    vetoed_section_count: usize,
    pages: *const FastdocMasterPageQuery,
    page_count: usize,
    out_template_index: *mut i64,
    out_capacity: usize,
) -> bool {
    clear_last_error();
    if (template_count > 0 && templates.is_null())
        || (vetoed_section_count > 0 && vetoed_sections.is_null())
        || (page_count > 0 && (pages.is_null() || out_template_index.is_null()))
        || page_count > out_capacity
    {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument or out buffer too small",
        ));
        return false;
    }
    // MARSHAL IN — owned copies of the template descriptors (mapped into the engine's own
    // vocabulary), a set for O(1) veto membership (what `sectionsHidingMasterPage.contains`
    // needs), and owned page queries.
    let template_descs: Vec<MasterTemplateDescriptor> = if template_count == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(templates, template_count)
            .iter()
            .map(|d| MasterTemplateDescriptor {
                section: d.section,
                applies_to: match d.applies_to {
                    1 => HeaderFooterApplicability::FirstPage,
                    2 => HeaderFooterApplicability::EvenPages,
                    _ => HeaderFooterApplicability::DefaultPages,
                },
            })
            .collect()
    };
    let vetoed: std::collections::HashSet<i64> = if vetoed_section_count == 0 {
        std::collections::HashSet::new()
    } else {
        std::slice::from_raw_parts(vetoed_sections, vetoed_section_count)
            .iter()
            .copied()
            .collect()
    };
    let page_queries: Vec<MasterPageQuery> = if page_count == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(pages, page_count)
            .iter()
            .map(|q| MasterPageQuery {
                page_index: q.page_index,
                section: q.has_section.then_some(q.section),
            })
            .collect()
    };
    let answers: Vec<i64> = guard_scalar(Vec::new(), move || {
        select_master_templates(&template_descs, &vetoed, &page_queries)
            .into_iter()
            .map(|index| index.map(|i| i as i64).unwrap_or(-1))
            .collect()
    });
    if answers.len() != page_count {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "internal: answer count did not match page_count",
        ));
        return false;
    }
    if page_count > 0 {
        let out = std::slice::from_raw_parts_mut(out_template_index, page_count);
        out.copy_from_slice(&answers);
    }
    true
}

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

/// Declares the text stack this process measures with (S5-02).
///
/// Same one-shot rule as `fastdoc_install_font_provider`: call once, before any ported layout
/// decision runs. A second call is ignored rather than swapped — two halves of one document
/// measured against different text stacks is worse than either.
///
/// # Safety
/// `callbacks.measure` must remain valid for the life of the process and must be safe to call
/// from any thread; see `swiftshim::text_measure`'s module doc for the payload's ownership rule.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_install_text_measurer(
    callbacks: swiftshim::text_measure::TextMeasureCallbacks,
) -> bool {
    // Guarded like every other export — see `fastdoc_install_font_provider`'s own comment for
    // why this is not merely defensive.
    guard_scalar(false, move || {
        swiftshim::text_measure::install_callbacks(callbacks)
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

    /// S5-02/S5-05, both through this crate's own error vocabulary: absence maps to
    /// `hostTextMeasurerMissing` before anything is installed, and a callback that re-enters a
    /// guarded export (the font provider's own hazard, S2B) does not lose the OUTER guarded
    /// call's failure location. One test, not several — `swiftshim::text_measure`'s `MEASURER`
    /// is a process-global `OnceLock` shared by every test in this binary, so the absence check
    /// has to run before the install below, in the same test, the way `font_provider.rs`'s own
    /// single-test precedent does it.
    #[test]
    fn text_measurer_missing_then_a_reentrant_callback_keeps_the_outer_panic_location() {
        let error = match swiftshim::text_measure::try_measurer() {
            Err(error) => error,
            Ok(_) => panic!("no measurer was installed"),
        };
        let failure = FfiFailure::from(error);
        assert_eq!(failure.kind, FfiErrorKind::HostTextMeasurerMissing);
        assert_eq!(failure.kind.tag(), "hostTextMeasurerMissing");
        assert!(failure.message.contains("no TextMeasurer installed"));

        // A callback that, when the host calls it, re-enters a GUARDED export and panics —
        // exactly the shape a real measurement callback has, since a host's text stack can
        // itself call back into this library. `guard_json`'s own save/restore is what must keep
        // this inner panic from clobbering the outer one below.
        extern "C" fn reentrant_measure(
            _payload: *const swiftshim::text_measure::TextMeasurePayload,
            _width_points: f64,
        ) -> f64 {
            let inner = guard_json(|| -> Result<String, FfiFailure> {
                panic!("inner panic that must not survive")
            });
            assert!(inner.is_null());
            crate::fastdoc_take_last_error(); // drain it; only the outer diagnostic matters here.
            0.0
        }
        assert!(swiftshim::text_measure::install_callbacks(
            swiftshim::text_measure::TextMeasureCallbacks { measure: reentrant_measure }
        ));

        let outer = guard_scalar(-1.0_f64, || -> f64 {
            let measurer = swiftshim::text_measure::try_measurer().expect("installed above");
            let resolved = swiftshim::text_measure::ResolvedText::default();
            let _ = measurer.measure(&resolved, 300.0); // runs the reentrant callback above
            panic!("outer panic that must survive")
        });
        assert_eq!(outer, -1.0, "the documented fallback must still come back");

        let diagnostic = crate::fastdoc_take_last_error();
        assert!(!diagnostic.is_null());
        let text = unsafe { CStr::from_ptr(diagnostic) }.to_str().unwrap().to_owned();
        unsafe { crate::fastdoc_string_free(diagnostic) };
        assert!(text.contains("outer panic that must survive"), "{text}");
        assert!(!text.contains("inner panic that must not survive"), "{text}");
        assert!(text.contains("lib.rs"), "the location must be THIS file's outer panic: {text}");
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
