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
//!    `fastdoc_extract_markdown`, `fastdoc_read_office_tree`,
//!    `fastdoc_take_last_error` — is a `CString::into_raw()` this library produced. The caller
//!    frees it with `fastdoc_string_free`, never with `free()` or its own allocator; the two
//!    allocators are not required to be interchangeable and are not assumed to be.
//! 2. **A failure is a value, not an exemption.** `fastdoc_read_office_tree`'s error envelope
//!    (`{"ffiVersion":1,"error":{...}}`) is exactly as owned as its ok envelope and must be freed
//!    the same way — this export never returns NULL for a document-level failure specifically so
//!    that both shapes go through one ownership rule instead of two.
//! 3. **NULL means nothing was allocated.** The only NULL a caller can receive is "the envelope
//!    itself could not be built" (`fastdoc_read_office_tree`) or "there is nothing to report"
//!    (`fastdoc_extract_markdown`, `fastdoc_take_last_error`). In
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

use fastdoc_engine::render::office::hwp_reader::mapping::{HwpReader, PictureBytes, RetainedParse};
use fastdoc_engine::render::office::{
    docx_reader::DocxReader, odt_reader::OdtReader,
    office_block::OfficeReadResult, office_markdown_serializer::OfficeMarkdownSerializer,
    zip_archive::ZipArchive,
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
    /// Carries the archive reader's OWN sentence. Discarding it with `map_err(|_| …)` is what
    /// made `--extract` answer a corrupt file with "the office archive is invalid" while `--pdf`,
    /// whose host-side zip open fails first, still said which structure was missing.
    InvalidArchive(String),
    UnsupportedExtension(String),
    Hwp(fastdoc_engine::render::office::hwp_reader::mapping::MapError),
    Reader(String),
}

impl fmt::Display for ReadOfficeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidArchive(detail) => f.write_str(detail),
            Self::UnsupportedExtension(extension) => {
                write!(f, "unsupported office extension: {extension}")
            }
            Self::Hwp(error) => write!(f, "HWP reader failed: {error}"),
            Self::Reader(error) => write!(f, "office reader failed: {error}"),
        }
    }
}

impl ReadOfficeError {
    fn kind(&self) -> FfiErrorKind {
        match self {
            Self::InvalidArchive(_) => FfiErrorKind::InvalidArchive,
            Self::UnsupportedExtension(_) => FfiErrorKind::UnsupportedExtension,
            Self::Hwp(_) => FfiErrorKind::HwpReadFailed,
            Self::Reader(_) => FfiErrorKind::ReaderFailed,
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
/// most likely to leak. A failure IS recorded for `fastdoc_take_last_error` now, so a caller
/// that wants a diagnostic for its own logs may still take one; nothing about the NULL contract
/// changes.
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

/// Reads an office document into the canonical `ValidatedRenderTree` wire form (S2B-03) and
/// returns it as a self-describing envelope — never NULL for a document-level failure, unlike
/// `fastdoc_extract_markdown` above:
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

/// Reads a TEXT document — markdown or plain text — into the same canonical `ValidatedRenderTree`
/// envelope `fastdoc_read_office_tree` returns, and by the same rules: the envelope is the
/// diagnostic channel, NULL only when the envelope itself could not be built, and the result is
/// owned by this library either way.
///
/// This exists so the format the app is NAMED for stops being the one format the host reads by
/// itself. `render::markdown::produce` and `render::plaintext::produce` have had parity tests since
/// S3 and no way to be called from outside the crate; a reader on another platform, and any
/// engine-versus-host comparison of the kind the office formats already get, both need this door.
///
/// Which producer runs is decided by EXTENSION, the same fork `DocumentTypes.kind(forExtension:)`
/// makes on the host: `md`/`markdown` parse as markdown, everything else this accepts is read
/// verbatim as decoded plain text, including unknown or empty extensions. Office extensions
/// are explicitly refused: their structured readers must handle the document.
///
/// # Safety
/// `bytes` must point to `len` readable bytes and `extension_` must be a NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_read_text_tree(
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
        let lowered = extension.to_lowercase();
        let source_name = format!("document.{lowered}");
        let tree = match lowered.as_str() {
            "md" | "markdown" => fastdoc_engine::render::markdown::produce(data, &source_name)
                .map_err(|error| {
                    FfiFailure::new(FfiErrorKind::ReaderFailed, format!("{error:?}"))
                })?,
            "docx" | "docm" | "dotx" | "dotm" | "odt" | "hwp" | "hwpx" => {
                return Err(FfiFailure::new(
                    FfiErrorKind::UnsupportedExtension,
                    format!("unsupported text extension: {lowered}"),
                ))
            }
            _ => fastdoc_engine::render::plaintext::produce_decoded(data, &source_name)
                .map_err(|error| FfiFailure::new(FfiErrorKind::ReaderFailed, format!("{error:?}")))?,
        };
        tree.encode_json()
            .map_err(|error| FfiFailure::new(FfiErrorKind::ExportFailed, format!("{error:?}")))
    })
}

/// Renders a MARKDOWN document all the way to the finished attributed string and hands it back on
/// the layer wire (`markdown_wire`), inside the same envelope every other call here uses.
///
/// This is the one format whose cost is not parsing — measured, 610 ms of a 708 ms render is the
/// attributed-string build — so unlike `fastdoc_read_text_tree` above, which hands over structure
/// for the host to typeset, this hands over typography the host only has to materialise.
///
/// `base_font_size` is the reader's own size, the single number `RenderTheme` is built from. It
/// crosses because the same document renders at different sizes and the engine must not guess one.
///
/// A font provider MUST be installed first (`fastdoc_install_font_provider`): the renderer builds
/// real `NSFont` values, and a world with no faces in it is a panic, not a plausible document.
///
/// # Safety
/// `bytes` must point to `len` readable bytes of UTF-8.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_render_markdown(
    bytes: *const u8,
    len: usize,
    base_font_size: f64,
) -> *mut c_char {
    if bytes.is_null() {
        return guard_envelope(|| {
            Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "invalid NULL argument",
            ))
        });
    }
    let data = std::slice::from_raw_parts(bytes, len);

    guard_envelope(move || {
        let Ok(source) = std::str::from_utf8(data) else {
            return Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "markdown source is not valid UTF-8",
            ));
        };
        if !(1.0..=512.0).contains(&base_font_size) {
            return Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                format!("base font size {base_font_size} is outside 1...512"),
            ));
        }
        let theme = fastdoc_engine::render::render_theme::RenderTheme::current(base_font_size);
        let rendered = fastdoc_engine::render::markdown_renderer::MarkdownRenderer::render_before_host_font_substitution(source, &theme);
        let wire = fastdoc_engine::render::markdown_wire::project(&rendered, &theme);
        serde_json::to_vec(&wire)
            .map_err(|error| FfiFailure::new(FfiErrorKind::ExportFailed, format!("{error:?}")))
    })
}

/// A markdown render handed over in PIECES, kept alive across calls.
///
/// Front-first paint puts the top of a long document on screen and finishes the rest afterwards,
/// which needs the builder to survive between chunks: block ids keep counting up across them and
/// each chunk's source offsets continue where the last one stopped (invariant 19). A stateless
/// "render blocks N..M" export cannot do that — it would restart the ids every call and produce two
/// neighbouring blocks that read as one stop for the reading cursor.
///
/// Same ownership rule as `fastdoc_office_open`: boxed out with `Box::into_raw`, taken back by
/// `fastdoc_markdown_progressive_close`, one owner and one close, held by the object that owns the
/// document's lifetime rather than in a `defer` at a call site.
pub struct FastdocMarkdownProgressive {
    render: fastdoc_engine::render::markdown_renderer::ProgressiveMarkdownRender,
    theme: fastdoc_engine::render::render_theme::RenderTheme,
}

/// Begins a progressive markdown render. Returns NULL and records the reason through
/// `fastdoc_take_last_error` when the source is not UTF-8 or the size is out of range.
///
/// # Safety
/// `bytes`/`len` describe a readable buffer for the duration of this call only.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_markdown_progressive_open(
    bytes: *const u8,
    len: usize,
    base_font_size: f64,
) -> *mut FastdocMarkdownProgressive {
    clear_last_error();
    if bytes.is_null() {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument",
        ));
        return std::ptr::null_mut();
    }
    let data = std::slice::from_raw_parts(bytes, len);
    guard_scalar(std::ptr::null_mut(), move || {
        let Ok(source) = std::str::from_utf8(data) else {
            set_last_error(&FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "markdown source is not valid UTF-8",
            ));
            return std::ptr::null_mut();
        };
        if !(1.0..=512.0).contains(&base_font_size) {
            set_last_error(&FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                format!("base font size {base_font_size} is outside 1...512"),
            ));
            return std::ptr::null_mut();
        }
        let theme = fastdoc_engine::render::render_theme::RenderTheme::current(base_font_size);
        let render = fastdoc_engine::render::markdown_renderer::MarkdownRenderer::render_progressive(
            source, &theme,
        );
        Box::into_raw(Box::new(FastdocMarkdownProgressive { render, theme }))
    })
}

/// Renders up to `blocks` more top-level blocks and returns them on the wire, in the same envelope
/// `fastdoc_render_markdown` uses; free with `fastdoc_string_free`.
///
/// The piece is finished the way `MarkdownRenderer.finishPasses` finishes one — autolink over the
/// chunk alone, which is safe because a top-level block boundary cannot fall inside a URL, a fence
/// or a word — and stops BEFORE font substitution, which the host owns (invariant 130).
///
/// # Safety
/// `handle` must be a live pointer `fastdoc_markdown_progressive_open` returned that has not been
/// closed.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_markdown_progressive_next(
    handle: *mut FastdocMarkdownProgressive,
    blocks: usize,
) -> *mut c_char {
    if handle.is_null() {
        return guard_envelope(|| {
            Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "invalid NULL argument",
            ))
        });
    }
    // `AssertUnwindSafe` because the render is MUTATED here and holds `Arc<dyn Any>` payloads, so
    // neither the reference nor its contents are unwind-safe by the compiler's rule. The claim
    // being asserted is narrow and true: if a chunk panics, the handle is left having advanced by
    // some blocks, and the only supported response to a failed chunk is to close the handle and
    // fall back to the host renderer — which is exactly what the Swift side does with the error
    // envelope this returns. Nothing reads a half-advanced handle.
    let state = std::panic::AssertUnwindSafe(&mut *handle);
    guard_envelope(move || {
        let state = state;
        let chunk = state.0.render.next_chunk_before_host_font_substitution(blocks);
        let wire = fastdoc_engine::render::markdown_wire::project(&chunk, &state.0.theme);
        serde_json::to_vec(&wire)
            .map_err(|error| FfiFailure::new(FfiErrorKind::ExportFailed, format!("{error:?}")))
    })
}

/// Whether every top-level block has been handed over. `1` finished, `0` not, `-1` for a NULL
/// handle — a negative can never be mistaken for either answer.
///
/// # Safety
/// `handle` must be either NULL or a live pointer `fastdoc_markdown_progressive_open` returned.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_markdown_progressive_is_finished(
    handle: *const FastdocMarkdownProgressive,
) -> i32 {
    // Same narrow claim as `..._next` above; this one only READS.
    let handle = std::panic::AssertUnwindSafe(handle);
    guard_scalar(-1, move || {
        let handle = handle;
        if handle.0.is_null() {
            return -1;
        }
        i32::from((*handle.0).render.is_finished())
    })
}

/// Closes a handle `fastdoc_markdown_progressive_open` returned. NULL is a no-op.
///
/// # Safety
/// `handle` must be either NULL or a pointer this crate returned and that has not already been
/// passed to this function.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_markdown_progressive_close(
    handle: *mut FastdocMarkdownProgressive,
) {
    let handle = std::panic::AssertUnwindSafe(handle);
    guard_scalar((), move || {
        let handle = handle;
        if !handle.0.is_null() {
            drop(Box::from_raw(handle.0));
        }
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

/// S5C1-01: an opaque document handle — a per-call export would re-read the document from bytes on
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
    /// What this document was opened AS. Kept so `fastdoc_office_tree_json` can package the
    /// result without being told again — the caller cannot get it wrong on the second call,
    /// because there is no second call to get wrong.
    extension_: String,
    /// Whatever this document's pictures can only be fetched from, kept alive for as long as the
    /// host holds the document (P2b). `None` for docx/odt, which have a zip the host holds itself.
    retained: Option<RetainedParse>,
    /// The name the adapter records this document under. Derived at open from the extension.
    source_name: String,
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
        match read_office_retaining_parse(data, extension) {
            Ok((result, retained)) => Box::into_raw(Box::new(FastdocOfficeDocument {
                result,
                retained,
                extension_: extension.to_string(),
                source_name: format!("document.{extension}"),
            })),
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

/// One embedded picture's bytes, base64, from the parse this handle still holds.
///
/// P2b: an HWP's pictures are reachable only through the rhwp parse that produced the document —
/// there is no archive to re-open, which is why the reader used to decode all of them during the
/// read and hand them over in one map. Keeping the parse alive lets a host ask for the one picture
/// it is about to draw instead.
///
/// `key` is the id the document's own blocks carry (`"hwpimg:3"`), so a caller passes back exactly
/// what it was given rather than reconstructing an index. Returns NULL for a key this document
/// does not have, for a document with no retained parse (docx/odt — their pictures come from the
/// zip the host holds), and for a malformed key: all three mean "ask somewhere else", and the
/// caller's fallback is the same for each.
///
/// # Safety
/// `handle` must be a live pointer `fastdoc_office_open` returned that has not been closed, and
/// `key` must be a NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_office_image_base64(
    handle: *const FastdocOfficeDocument,
    key: *const c_char,
) -> *mut c_char {
    clear_last_error();
    if handle.is_null() || key.is_null() {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument",
        ));
        return std::ptr::null_mut();
    }
    let document = &*handle;
    let Ok(key) = CStr::from_ptr(key).to_str() else {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "key is not valid UTF-8",
        ));
        return std::ptr::null_mut();
    };
    guard_json(move || {
        let retained = document.retained.as_ref().ok_or_else(|| {
            FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "this document keeps no parse to fetch pictures from",
            )
        })?;
        // The id parse AND the crop both live in the engine's own resolver, the same one the
        // read's image walk uses. Re-spelling either here is how this call would start answering
        // bytes the reader never drew — which it did, until the byte-identity gate caught a cropped
        // picture coming back uncropped.
        match retained.picture_for_id(key) {
            PictureBytes::Bytes(data) => {
                use base64::Engine;
                Ok(base64::engine::general_purpose::STANDARD.encode(&data.0))
            }
            PictureBytes::DeclaredWithoutBytes => Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "the document names this picture but declares no bytes for it",
            )),
            PictureBytes::Undecodable => Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "this picture's bytes did not decode",
            )),
            PictureBytes::NotAPictureOfThisDocument => Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "key does not name an embedded HWP picture",
            )),
        }
    })
}

/// The canonical-tree export of a document this handle ALREADY read — `fastdoc_read_office_tree`
/// without its read.
///
/// U3 (`docs/06-research/2026-09-04-rendertree-gap-audit.md` §2): this is a SECOND projection of
/// the same parsed model the handle already holds — `document.result`, never re-read from bytes —
/// so it pays none of the 565 ms `fastdoc_read_office_tree` would spend re-parsing the document
/// from scratch. `bytes`/`len` are taken because the adapter records the source's sha256 and
/// length from them, not a second copy of the document kept alive in the handle.
///
/// Returns the SAME self-describing envelope `fastdoc_read_office_tree` returns — never NULL for
/// a document-level failure (including a NULL handle/bytes, unlike this file's `guard_json`-based
/// exports), owned by this library in both shapes, and freed with `fastdoc_string_free` either
/// way. NULL comes back only when the envelope itself could not be built, exactly as documented on
/// `fastdoc_read_office_tree`.
///
/// # Safety
/// `handle` must be a live pointer `fastdoc_office_open` returned that has not been closed, and
/// `bytes` must point to `len` readable bytes for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_office_tree_json(
    handle: *const FastdocOfficeDocument,
    bytes: *const u8,
    len: usize,
) -> *mut c_char {
    if handle.is_null() || bytes.is_null() {
        return guard_envelope(|| {
            Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "invalid NULL argument",
            ))
        });
    }
    let document = &*handle;
    let data = std::slice::from_raw_parts(bytes, len);
    guard_envelope(move || {
        let format = document_format(&document.extension_).map_err(FfiFailure::from)?;
        let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
            format,
            source_name: &document.source_name,
            source_bytes: data,
            result: &document.result,
            resources: BTreeMap::new(),
        })
        .map_err(|error| FfiFailure::new(FfiErrorKind::ExportFailed, format!("{error:?}")))?;
        tree.encode_json()
            .map_err(|error| FfiFailure::new(FfiErrorKind::ExportFailed, format!("{error:?}")))
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

/// S2 of `docs/plans/pagination-to-engine.md`: the PAGE PLAN — where every whole block of a paged
/// document goes, decided once, from the heights the host observed.
///
/// `input_json` is a `PlanInput` (`render/office/page_plan.rs`): the page body height, the table
/// split preference, optional per-page footnote reservations, and one entry per flow block carrying
/// an opaque host `key` (the RenderTree node id on the Avalonia host), its page flags (section
/// start, hard break, keep-with-next, blank), and what the host measured (line boxes, a picture's
/// height, table row heights). The answer is keyed by the same keys and by block index, and carries
/// no text: it is geometry over node ids, not a second projection of the document (plan D2).
///
/// Returns `{"ffiVersion":1,"ok":<PagePlanV1>}` or `{"ffiVersion":1,"error":{...}}`, owned by this
/// library and freed with `fastdoc_string_free` — the envelope shape `fastdoc_office_tree_json`
/// uses. NULL only when the envelope itself could not be built. `handle` is the open document the
/// plan belongs to; the arithmetic needs no document state, so
/// it is never dereferenced — NULL is allowed, for a caller that plans heights it measured without
/// holding an open document.
///
/// # Safety
/// `handle` must be either NULL or a live pointer `fastdoc_office_open` returned that has not been
/// closed. `input_json` must be a NUL-terminated string valid for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_office_page_plan_json(
    _handle: *const FastdocOfficeDocument,
    input_json: *const c_char,
) -> *mut c_char {
    use fastdoc_engine::render::office::page_plan::{plan_pages, PlanInput};

    if input_json.is_null() {
        return guard_envelope(|| {
            Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "invalid NULL argument",
            ))
        });
    }
    let text = match CStr::from_ptr(input_json).to_str() {
        Ok(text) => text.to_owned(),
        Err(_) => {
            return guard_envelope(|| {
                Err(FfiFailure::new(
                    FfiErrorKind::InvalidArgument,
                    "the page plan input is not valid UTF-8",
                ))
            })
        }
    };
    guard_envelope(move || {
        let input: PlanInput = serde_json::from_str(&text).map_err(|error| {
            FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                format!("the page plan input is not a PlanInput: {error}"),
            )
        })?;
        let plan = plan_pages(&input)
            .map_err(|error| FfiFailure::new(FfiErrorKind::InvalidArgument, error.to_string()))?;
        serde_json::to_vec(&plan)
            .map_err(|error| FfiFailure::new(FfiErrorKind::ExportFailed, format!("{error}")))
    })
}

/// S3 of `docs/plans/pagination-to-engine.md`: the LINE MODEL — how tall a paragraph's lines stand
/// and how tall a table row is, from the line boxes the host's own layout produced.
///
/// `input_json` is a `LineModelInput` (`render/office/line_model.rs`): the document's line grid,
/// body paragraphs and tables. A paragraph carries each line's natural box, its line-height rule,
/// character size, spacing and whether the format puts its spacing below the glyphs; a table carries
/// its cells' stacked paragraphs and boxes, paddings and declared heights. The answer is the placed
/// line heights (and the spacing a page may let hang), each cell's line tops and every row's height.
/// It carries no text and shapes nothing: the host measures, the engine decides what the document's
/// rules make of what was measured (plan D1).
///
/// Returns `{"ffiVersion":1,"ok":<LineModelOutput>}` or `{"ffiVersion":1,"error":{...}}`, owned by
/// this library and freed with `fastdoc_string_free`. NULL only when the envelope itself could not
/// be built. The arithmetic needs no document state, so there is no handle.
///
/// # Safety
/// `input_json` must be a NUL-terminated string valid for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn fastdoc_office_line_model_json(input_json: *const c_char) -> *mut c_char {
    use fastdoc_engine::render::office::line_model::{solve, LineModelInput};

    if input_json.is_null() {
        return guard_envelope(|| {
            Err(FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                "invalid NULL argument",
            ))
        });
    }
    let text = match CStr::from_ptr(input_json).to_str() {
        Ok(text) => text.to_owned(),
        Err(_) => {
            return guard_envelope(|| {
                Err(FfiFailure::new(
                    FfiErrorKind::InvalidArgument,
                    "the line model input is not valid UTF-8",
                ))
            })
        }
    };
    guard_envelope(move || {
        let input: LineModelInput = serde_json::from_str(&text).map_err(|error| {
            FfiFailure::new(
                FfiErrorKind::InvalidArgument,
                format!("the line model input is not a LineModelInput: {error}"),
            )
        })?;
        let answer = solve(&input)
            .map_err(|error| FfiFailure::new(FfiErrorKind::InvalidArgument, error.to_string()))?;
        serde_json::to_vec(&answer)
            .map_err(|error| FfiFailure::new(FfiErrorKind::ExportFailed, format!("{error}")))
    })
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

/// One footnote's own answer — `(number, height)`, an "entry struct, not parallel
/// arrays" shape (`s5d2.md`'s own API section: "번호와 높이가 갈라질 수
/// 없게"). `#[repr(C)]` so the layout is exactly what the header declares.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct FastdocFootnoteHeightDesc {
    pub number: i64,
    pub height: CGFloat,
}

/// `fastdoc_office_footnote_heights` — S5D-2: `PageBandGeometry::built_height`, called once per
/// footnote this handle's own parse holds, batched into ONE crossing (S5C-3's own batch
/// discipline — never once per note). Calls no new arithmetic; the port is exactly
/// `footnote_heights`, which calls `built_height` unchanged.
///
/// Keyed by the document's own NUMBER (`OfficeFootnote.number`), never position — the host's own
/// `officeFootnotes` comes from a SEPARATE parse of the same bytes (`DocumentTypes.readOffice`'s
/// `RustEngine.readOffice`, not this handle's `read_office`), and an index into this handle's own
/// array has no guaranteed relationship to the host's array once the two paths diverge — `s5d2.md`'s
/// own risk section.
///
/// **Out:** `out_entries[0..returned]`, in the SAME order this handle's own `footnotes` are held
/// (not sorted — there is no `HashMap` here to randomize). Returns the count actually written, or a
/// NEGATIVE value on any refusal (`fastdoc_take_last_error` names it): a NULL handle, an output
/// buffer smaller than the footnote count, or the first note `built_height` itself could not
/// measure (no measurer installed, or an unresolved attachment). A refusal is never a partial
/// count — the whole batch is refused together, matching `footnote_heights`' own `Err`-on-first-miss
/// contract, because a map short one entry reserves that note's page short by exactly its height
/// (invariant 98's corrupt half).
///
/// # Safety
/// `handle` must be either NULL or a live pointer `fastdoc_office_open` returned that has not been
/// closed. `out_entries`/`out_capacity` describe a writable buffer for the duration of the call.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fastdoc_office_footnote_heights(
    handle: *const FastdocOfficeDocument,
    column_width: f64,
    page_content_width: f64,
    has_page_content_width: bool,
    document_default_font_size: f64,
    out_entries: *mut FastdocFootnoteHeightDesc,
    out_capacity: usize,
) -> i64 {
    clear_last_error();
    if handle.is_null() || (out_capacity > 0 && out_entries.is_null()) {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "invalid NULL argument",
        ));
        return -1;
    }
    let handle_ref: &FastdocOfficeDocument = &*handle;
    let page_content_width = has_page_content_width.then_some(page_content_width);
    let heights: Option<Vec<(i64, CGFloat)>> = guard_scalar(None, move || {
        let result = &handle_ref.result;
        let theme = fastdoc_engine::render::render_theme::RenderTheme::current(document_default_font_size);
        match fastdoc_engine::render::office::page_band_geometry::PageBandGeometry::footnote_heights(
            &result.footnotes, &theme, column_width, document_default_font_size, page_content_width,
        ) {
            Ok(entries) => Some(entries),
            Err(error) => {
                set_last_error(&FfiFailure::new(
                    FfiErrorKind::HostTextMeasurerMissing,
                    format!("{error}"),
                ));
                None
            }
        }
    });
    let Some(entries) = heights else { return -1 };
    if entries.len() > out_capacity {
        set_last_error(&FfiFailure::new(
            FfiErrorKind::InvalidArgument,
            "out buffer too small for the footnote count",
        ));
        return -1;
    }
    if !entries.is_empty() {
        let out = std::slice::from_raw_parts_mut(out_entries, entries.len());
        for (i, (number, height)) in entries.iter().enumerate() {
            out[i] = FastdocFootnoteHeightDesc { number: *number, height: *height };
        }
    }
    entries.len() as i64
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
    read_office_retaining_parse(data, extension).map(|(result, _)| result)
}

/// The same read, keeping alive whatever the document's pictures can only be fetched FROM.
///
/// P2b: only HWP has such a thing. An `.hwp` is CFB binary, so its embedded pictures are reachable
/// only through the rhwp parse that produced the document — which is why the reader decodes every
/// one of them during the read, and why a 10.7 MB document exports 54 MB of base64. docx and odt
/// have no equivalent: their pictures live in a zip the HOST already holds open, which is exactly
/// why they never had this problem.
///
/// `None` for those formats, therefore, is not a gap. It is the honest answer to "what does this
/// document need kept open" for a document that needs nothing kept open.
fn read_office_retaining_parse(
    data: &[u8],
    extension: &str,
) -> Result<(OfficeReadResult, Option<RetainedParse>), ReadOfficeError> {
    // HWP is answered BEFORE the archive is opened, not after. `.hwp` is CFB binary rather than a
    // zip, so opening one as an archive fails and the reader would never be reached — which is how
    // the host's own dispatch does it too (`DocumentTypes.isHwp` branches ahead of `ZipArchive`).
    if matches!(extension.to_lowercase().as_str(), "hwp" | "hwpx") {
        return HwpReader::read_retaining_parse(&swiftshim::Data::fromBytes(data.to_vec()), false)
            .map(|(result, retained)| (result, Some(retained)))
            .map_err(ReadOfficeError::Hwp);
    }
    let archive = ZipArchive::new(swiftshim::Data::fromBytes(data.to_vec()))
        .map_err(|error| ReadOfficeError::InvalidArchive(error.to_string()))?;
    match extension.to_lowercase().as_str() {
        "docx" | "docm" | "dotx" | "dotm" => DocxReader::read(&archive)
            .map(|result| (result, None))
            .map_err(|error| ReadOfficeError::Reader(error.to_string())),
        "odt" => OdtReader::read(&archive)
            .map(|result| (result, None))
            .map_err(|error| ReadOfficeError::Reader(format!("{error:?}"))),
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
    Some(OfficeMarkdownSerializer::serialize_result(&result))
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
            unsafe { fastdoc_office_open(data.as_ptr(), data.len(), extension.as_ptr()) };
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
            swiftshim::text_measure::TextMeasureCallbacks { measure: reentrant_measure, measure_lines: None }
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
