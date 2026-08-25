//! The containment core every export goes through, plus its two return-shape wrappers.
//!
//! A panic unwinding across the C ABI into Swift's frames is undefined behaviour. `catch_unwind`
//! appears exactly ONCE in this crate — in `contain`, below — and every export reaches it through
//! `guard_json` or `guard_scalar` rather than calling `catch_unwind` itself. That is what makes
//! `grep -c catch_unwind` a meaningful check instead of a coincidence.
//!
//! Containment only works because this workspace unwinds on panic. A profile that sets
//! `panic = "abort"` would turn every one of these guards into a silent process kill, so the crate
//! refuses to compile under that setting rather than failing that assumption invisibly.
#[cfg(panic = "abort")]
compile_error!(
    "fastdoc-ffi's panic containment (ffi_guard::contain) assumes `panic = \"unwind\"`. Under \
     `panic = \"abort\"` every guarded call becomes a silent process kill instead of a caught, \
     reported failure — remove the abort profile or teach this crate a different containment \
     strategy before enabling it."
);

use std::any::Any;
use std::cell::Cell;
use std::ffi::CString;
use std::panic::{self, UnwindSafe};
use std::sync::Once;

/// The closed set of tags a caller branches on. Adding a new failure means adding a variant here
/// and to `tag`, and nowhere else.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FfiErrorKind {
    InvalidArgument,
    InvalidArchive,
    UnsupportedExtension,
    HwpReadFailed,
    ReaderFailed,
    ExportFailed,
    InteriorNul,
    Panic,
    HostFontProviderMissing,
}

impl FfiErrorKind {
    /// The wire tag. Swift mirrors this list in
    /// `Sources/FastDocReader/Render/Office/RustCanonicalTree.swift` (`KnownKind`), which has no way
    /// to see this file — `tags_are_frozen_because_swift_mirrors_them` below is what makes a rename
    /// here fail loudly instead of silently turning every `known` on the host into `nil`.
    pub(crate) fn tag(self) -> &'static str {
        match self {
            Self::InvalidArgument => "invalidArgument",
            Self::InvalidArchive => "invalidArchive",
            Self::UnsupportedExtension => "unsupportedExtension",
            Self::HwpReadFailed => "hwpReadFailed",
            Self::ReaderFailed => "readerFailed",
            Self::ExportFailed => "exportFailed",
            Self::InteriorNul => "interiorNul",
            Self::Panic => "panic",
            Self::HostFontProviderMissing => "hostFontProviderMissing",
        }
    }
}

/// A failure that crossed the guard: what kind, a message for humans, and — for a caught panic —
/// where it happened.
#[derive(Debug)]
pub(crate) struct FfiFailure {
    pub(crate) kind: FfiErrorKind,
    pub(crate) message: String,
    pub(crate) location: Option<String>,
}

impl FfiFailure {
    pub(crate) fn new(kind: FfiErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            location: None,
        }
    }

    /// The text recorded for `fastdoc_take_last_error`: real JSON, built through `serde_json`
    /// rather than hand-escaped, because this is the one code path that only runs after something
    /// has already gone wrong and a hand-rolled escaper is a defect waiting to happen there. A
    /// caller that only ever reads a string still gets one (the `message` field reads exactly as
    /// the old plain-text diagnostic did); a caller that decodes it as JSON gets `kind` without
    /// parsing prose.
    pub(crate) fn to_last_error_json(&self) -> String {
        let value = serde_json::json!({
            "kind": self.kind.tag(),
            "message": self.message,
            "location": self.location,
        });
        serde_json::to_string(&value).unwrap_or_else(|_| {
            format!(
                "{{\"kind\":\"{}\",\"message\":\"office reader failed with an unencodable diagnostic\",\"location\":null}}",
                self.kind.tag()
            )
        })
    }
}

// ---------------------------------------------------------------------------------------------
// Panic location capture.
//
// A panic hook runs BEFORE the stack unwinds, so it is the only place that ever sees
// `Location`. `catch_unwind`'s payload carries the panic message but not where it happened, so
// the hook's only job is recording where, as cheaply and safely as possible: a panic inside the
// panic hook is a double panic, and Rust aborts the process for that. The hook therefore stores
// only `Copy` data into a `Cell` (never a `RefCell`, whose borrow could already be held) and
// allocates nothing that could itself fail to allocate.
// ---------------------------------------------------------------------------------------------

thread_local! {
    static PANIC_LOCATION: Cell<Option<(&'static str, u32, u32)>> = const { Cell::new(None) };
}

static INSTALL_HOOK: Once = Once::new();

fn install_hook_once() {
    INSTALL_HOOK.call_once(|| {
        let previous = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            if let Some(location) = info.location() {
                // SAFETY: a panic location is always the compiler's `file!()` literal, which is
                // `'static` for the whole process — the string data neither moves nor frees. The
                // hook API merely elides that to the borrow of `PanicHookInfo`; this recovers the
                // lifetime the data actually has rather than extending one that does not exist.
                let file: &'static str = unsafe { std::mem::transmute(location.file()) };
                let _ = PANIC_LOCATION.try_with(|cell| {
                    cell.set(Some((file, location.line(), location.column())));
                });
            }
            previous(info);
        }));
    });
}

fn panic_message(payload: &(dyn Any + Send)) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "office reader panicked".to_string()
    }
}

/// The containment core. Every export reaches `catch_unwind` through here — nowhere else.
///
/// The captured-location slot is saved before `f` runs and restored after, so a re-entrant
/// guarded call on this thread (the font-provider callback can call back into a guarded export
/// while this one is still on the stack) cannot leave its own location sitting in the slot for an
/// unrelated, later panic at this level to misattribute. `LAST_ERROR` is NOT saved/restored this
/// way — it is deliberately last-write-wins by its existing, pre-S2B contract.
fn contain<T>(f: impl FnOnce() -> T + UnwindSafe) -> Result<T, FfiFailure> {
    install_hook_once();
    let saved = PANIC_LOCATION.with(Cell::take);
    let outcome = panic::catch_unwind(f);
    let captured = PANIC_LOCATION.with(|cell| cell.replace(saved));
    match outcome {
        Ok(value) => Ok(value),
        Err(payload) => {
            let message = panic_message(payload.as_ref());
            let location = captured.map(|(file, line, column)| format!("{file}:{line}:{column}"));
            Err(FfiFailure {
                kind: FfiErrorKind::Panic,
                message,
                location,
            })
        }
    }
}

/// The wrapper for exports that return a `*mut c_char` payload the host reads as text (Markdown,
/// or a JSON string the export already formatted). `f` returns the payload directly — no envelope
/// is imposed here, because the exports that exist today must keep returning exactly what they
/// return now (NULL on failure, the raw payload on success); a fixed `{ok, error}` envelope is
/// S2B-03's canonical-tree export, not a retrofit onto these.
///
/// On failure — a caught panic, `f` returning `Err`, or the payload containing an interior NUL —
/// the discriminated failure is recorded where `fastdoc_take_last_error` retrieves it, and NULL
/// is returned.
pub(crate) fn guard_json(
    f: impl FnOnce() -> Result<String, FfiFailure> + UnwindSafe,
) -> *mut std::ffi::c_char {
    let outcome = match contain(f) {
        Ok(inner) => inner,
        Err(failure) => Err(failure),
    };
    match outcome {
        Ok(payload) => match CString::new(payload) {
            Ok(c) => c.into_raw(),
            Err(_) => {
                crate::set_last_error(&FfiFailure::new(
                    FfiErrorKind::InteriorNul,
                    "office JSON contained an interior NUL byte",
                ));
                std::ptr::null_mut()
            }
        },
        Err(failure) => {
            crate::set_last_error(&failure);
            std::ptr::null_mut()
        }
    }
}

/// The wrapper for `fastdoc_office_default_body_font_size`, which returns `f64` and has nowhere
/// to put an error envelope. On failure the fallback that export already documents is returned,
/// and the failure is recorded where `fastdoc_take_last_error` can still retrieve it.
pub(crate) fn guard_scalar<T>(fallback: T, f: impl FnOnce() -> T + UnwindSafe) -> T {
    match contain(f) {
        Ok(value) => value,
        Err(failure) => {
            crate::set_last_error(&failure);
            fallback
        }
    }
}

/// The wrapper for `fastdoc_read_office_tree` (S2B-03). Unlike `guard_json`, a failure never
/// returns NULL here — it returns `{"ffiVersion":1,"error":{"kind","message","location"}}`,
/// still owned by this library and still freed with `fastdoc_string_free`. NULL means only that
/// the ENVELOPE ITSELF could not be built (its JSON text was somehow not valid UTF-8, or an
/// interior NUL landed in it) — there is nothing for the caller to own in that case, so this does
/// not route through `crate::set_last_error`/`fastdoc_take_last_error` at all: the envelope IS
/// the diagnostic channel for this export.
///
/// `f` returns the "ok" half's ALREADY-ENCODED tree bytes (`ValidatedRenderTree::encode_json`'s
/// output) so this function can splice them into the envelope verbatim through
/// `serde_json::value::RawValue` rather than decoding and re-encoding them — S2B-03's contract is
/// that the tree's bytes cross the boundary unchanged, byte for byte.
pub(crate) fn guard_envelope(
    f: impl FnOnce() -> Result<Vec<u8>, FfiFailure> + UnwindSafe,
) -> *mut std::ffi::c_char {
    let result: Result<Vec<u8>, FfiFailure> = match contain(f) {
        Ok(inner) => inner,
        Err(panic_failure) => Err(panic_failure),
    };
    let envelope = match result {
        Ok(tree_json) => encode_ok_envelope(tree_json),
        Err(failure) => Some(encode_error_envelope(&failure)),
    };
    match envelope.and_then(|text| CString::new(text).ok()) {
        Some(c) => c.into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// `{"ffiVersion":1,"ok":<tree JSON, verbatim>}`, or `None` if the tree bytes were not valid
/// UTF-8 (never true for real `encode_json` output — `serde_json` always emits UTF-8 — but this
/// stays a checked path rather than an `unwrap` because it crosses the ABI) or the envelope
/// itself failed to serialize.
fn encode_ok_envelope(tree_json: Vec<u8>) -> Option<String> {
    #[derive(serde::Serialize)]
    struct OkEnvelope<'a> {
        #[serde(rename = "ffiVersion")]
        ffi_version: u32,
        ok: &'a serde_json::value::RawValue,
    }
    let raw_text = String::from_utf8(tree_json).ok()?;
    let raw = serde_json::value::RawValue::from_string(raw_text).ok()?;
    serde_json::to_string(&OkEnvelope { ffi_version: 1, ok: &raw }).ok()
}

/// `{"ffiVersion":1,"error":{"kind","message","location"}}` — the same three fields
/// `to_last_error_json` reports, under the same `error` key the ok half's sibling `ok` key
/// implies, so a caller that already parses one recognises the other.
fn encode_error_envelope(failure: &FfiFailure) -> String {
    let value = serde_json::json!({
        "ffiVersion": 1,
        "error": {
            "kind": failure.kind.tag(),
            "message": failure.message,
            "location": failure.location,
        }
    });
    serde_json::to_string(&value).unwrap_or_else(|_| {
        format!(
            "{{\"ffiVersion\":1,\"error\":{{\"kind\":\"{}\",\"message\":\"office reader failed with an unencodable diagnostic\",\"location\":null}}}}",
            failure.kind.tag()
        )
    })
}

#[cfg(test)]
mod tests {

    /// A rename here is invisible to Swift until something fails. This is that something.
    /// Adding a variant is already forced to touch `tag`'s exhaustive match; this freezes the
    /// STRINGS, which is the half a compiler cannot check across a language boundary.
    #[test]
    fn tags_are_frozen_because_swift_mirrors_them() {
        use FfiErrorKind::*;
        let pairs = [
            (InvalidArgument, "invalidArgument"),
            (InvalidArchive, "invalidArchive"),
            (UnsupportedExtension, "unsupportedExtension"),
            (HwpReadFailed, "hwpReadFailed"),
            (ReaderFailed, "readerFailed"),
            (ExportFailed, "exportFailed"),
            (InteriorNul, "interiorNul"),
            (Panic, "panic"),
            (HostFontProviderMissing, "hostFontProviderMissing"),
        ];
        for (kind, expected) in pairs {
            assert_eq!(kind.tag(), expected, "wire tag changed without updating the Swift mirror");
        }
    }

    use super::*;
    use std::ffi::CStr;

    /// The floor for S2B-01: an input that ACTUALLY panics, run through the same `guard_json`
    /// every real pointer-returning export uses, must come back as a typed failure — not an
    /// unwind, not a swallowed payload.
    #[test]
    fn guard_json_panic_returns_typed_failure_with_location() {
        let result = guard_json(|| -> Result<String, FfiFailure> {
            panic!("deliberate panic for guard_json coverage")
        });
        assert!(result.is_null(), "a panicking export must return NULL");

        let diagnostic = crate::fastdoc_take_last_error();
        assert!(
            !diagnostic.is_null(),
            "a panic must leave a retrievable diagnostic"
        );
        let text = unsafe { CStr::from_ptr(diagnostic) }
            .to_str()
            .unwrap()
            .to_owned();
        unsafe { crate::fastdoc_string_free(diagnostic) };

        let parsed: serde_json::Value = serde_json::from_str(&text).expect(&text);
        assert_eq!(parsed["kind"], "panic");
        assert!(
            parsed["message"]
                .as_str()
                .unwrap()
                .contains("deliberate panic for guard_json coverage"),
            "{text}"
        );
        let location = parsed["location"].as_str().expect("location must be set");
        assert!(location.contains("ffi_guard.rs"), "{location}");
    }

    /// The scalar wrapper has no envelope to put a failure in, so its contract is: the documented
    /// fallback comes back AND the failure is still retrievable through the existing call.
    #[test]
    fn guard_scalar_panic_returns_fallback_and_records_error() {
        crate::fastdoc_take_last_error(); // drain anything a prior test in this binary left.
        let value = guard_scalar(11.0_f64, || -> f64 { panic!("deliberate scalar panic") });
        assert_eq!(value, 11.0, "the documented fallback must still come back");

        let diagnostic = crate::fastdoc_take_last_error();
        assert!(!diagnostic.is_null());
        let text = unsafe { CStr::from_ptr(diagnostic) }
            .to_str()
            .unwrap()
            .to_owned();
        unsafe { crate::fastdoc_string_free(diagnostic) };
        assert!(text.contains("deliberate scalar panic"), "{text}");
        assert!(text.contains("\"kind\":\"panic\""), "{text}");
    }

    /// A guarded call inside a guarded call — the shape the font-provider callback creates — must
    /// not let the inner failure erase the outer one.
    #[test]
    fn nested_guard_reports_the_outer_panic() {
        let outer = guard_json(|| -> Result<String, FfiFailure> {
            let inner = guard_json(|| -> Result<String, FfiFailure> {
                panic!("inner panic that must not survive")
            });
            assert!(inner.is_null());
            // Consume the inner diagnostic the way a real caller would, but keep the LOCATION it
            // reported. The message alone cannot test save/restore: a message comes from
            // `catch_unwind`'s payload and is correct either way. The location is the thing the
            // slot holds, so it is the only thing that can be misattributed.
            let inner_diag = crate::fastdoc_take_last_error();
            assert!(!inner_diag.is_null(), "the inner panic must have recorded a diagnostic");
            let inner_text = unsafe { CStr::from_ptr(inner_diag) }.to_str().unwrap().to_owned();
            unsafe { crate::fastdoc_string_free(inner_diag) };
            let inner_location = location_of(&inner_text)
                .unwrap_or_else(|| panic!("inner diagnostic carried no location: {inner_text}"));
            INNER_LOCATION.with(|slot| { *slot.borrow_mut() = Some(inner_location); });
            panic!("outer panic that must survive")
        });
        assert!(outer.is_null());

        let diagnostic = crate::fastdoc_take_last_error();
        assert!(!diagnostic.is_null());
        let text = unsafe { CStr::from_ptr(diagnostic) }
            .to_str()
            .unwrap()
            .to_owned();
        unsafe { crate::fastdoc_string_free(diagnostic) };
        assert!(text.contains("outer panic that must survive"), "{text}");
        assert!(!text.contains("inner panic that must not survive"), "{text}");

        let outer_location = location_of(&text)
            .unwrap_or_else(|| panic!("outer diagnostic carried no location: {text}"));
        let inner_location = INNER_LOCATION
            .with(|slot| slot.borrow_mut().take())
            .expect("the inner panic's location was never recorded");
        assert_ne!(
            outer_location, inner_location,
            "the outer failure is reporting the INNER panic's location — the captured-location \
             slot was not restored around the nested call"
        );
    }

    thread_local! {
        static INNER_LOCATION: std::cell::RefCell<Option<String>> =
            const { std::cell::RefCell::new(None) };
    }

    /// The `location` field out of a recorded diagnostic, without pulling in a JSON parser for
    /// one field in a test.
    fn location_of(diagnostic: &str) -> Option<String> {
        let key = "\"location\":\"";
        let start = diagnostic.find(key)? + key.len();
        let rest = &diagnostic[start..];
        let end = rest.find('"')?;
        Some(rest[..end].to_string())
    }
}
