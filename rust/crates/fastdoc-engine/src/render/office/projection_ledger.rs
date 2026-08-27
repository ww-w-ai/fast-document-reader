//! S4-05 — the record of every document that took the reader path instead of the tree path.
//!
//! `fastdoc_read_office_json` (`fastdoc-ffi`) tries `ValidatedRenderTree::from_office` then
//! `office_project::project` before it ever falls back to `office_export::to_json`. When either
//! step refuses, the fallback is not silent: this module is where the refusal is written down —
//! the document's own name, and the error that sent it back to the reader path.
//!
//! S4-03's refusal census counts `from_office` outcomes over the registered fixtures, tabulated by
//! `adapter_error_kind` below; this ledger records the SAME kind string when a real read falls
//! back for the same reason, in-process, at the FFI boundary. A test that runs the same document
//! through both is what proves the two never drift apart — "the ledger is non-empty" would still
//! pass if forty-nine of fifty refusals were swallowed, so the acceptance is a per-kind count
//! match, not a non-emptiness check (`fastdoc-ffi/tests/office_fallback_ledger_ffi.rs`).
//!
//! In-process only, deliberately: this sprint is a cutover, not a logging feature, so nothing here
//! touches a file or a socket. `clear()` exists for tests, which must not see a previous test's
//! entries — `cargo test` runs a crate's tests in one process, sharing this `static`.

use std::sync::Mutex;

use crate::render::office::office_project::ProjectionError;
use crate::render::render_tree::OfficeAdapterError;

/// One fallback: which document, and why the tree path could not carry it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerEntry {
    /// The document's own name — `source_name` at the FFI boundary, or a fixture's name in a
    /// test — never a synthetic id, so a human reading the ledger can find the file.
    pub document_name: String,
    /// The bucket a fallback is grouped under. `"OfficeAdapterError::<Variant>"` for a
    /// `from_office` refusal (the kind S4-03's census also counts, via `adapter_error_kind`),
    /// `"ProjectionError::Field(<name>)"` / `"ProjectionError::Malformed"` for a `project`
    /// refusal — the two stages are prefixed differently on purpose so a reader (and a
    /// cross-check test) can tell which stage sent a document back without re-parsing `detail`.
    pub kind: String,
    /// The error's own `Debug` text (or `ProjectionError::description()`), kept for a human
    /// reading the ledger — never parsed by the cross-check, which compares `kind` alone.
    pub detail: String,
}

static LEDGER: Mutex<Vec<LedgerEntry>> = Mutex::new(Vec::new());

/// Records one fallback. Never panics on a poisoned lock — a prior panic while holding it must
/// not stop every later document from being recorded, so a poisoned mutex is recovered rather
/// than propagated.
fn with_ledger<T>(f: impl FnOnce(&mut Vec<LedgerEntry>) -> T) -> T {
    let mut guard = LEDGER.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    f(&mut guard)
}

/// Appends one entry. Called from the FFI fallback branch (real documents) and from tests that
/// cross-check it (same call, same bytes, so the recorded `kind` is provably the one the fixture
/// actually produced, not a guess).
pub fn record(document_name: impl Into<String>, kind: impl Into<String>, detail: impl Into<String>) {
    with_ledger(|entries| {
        entries.push(LedgerEntry {
            document_name: document_name.into(),
            kind: kind.into(),
            detail: detail.into(),
        });
    });
}

/// A snapshot of every entry recorded so far, in recording order.
pub fn snapshot() -> Vec<LedgerEntry> {
    with_ledger(|entries| entries.clone())
}

/// Empties the ledger. Test-only in practice (nothing at the FFI boundary ever needs to forget a
/// fallback), but not `#[cfg(test)]`: `fastdoc-ffi`'s tests call it across the crate boundary,
/// where `cfg(test)` would not be set for THIS crate's build.
pub fn clear() {
    with_ledger(|entries| entries.clear());
}

/// The bucket name for an `OfficeAdapterError` — the one place this mapping is written, so
/// S4-03's census (`fastdoc-engine/tests/office_projection_refusal_census.rs`) and this ledger's
/// own callers can never name the same variant two different ways.
pub fn adapter_error_kind(error: &OfficeAdapterError) -> &'static str {
    match error {
        OfficeAdapterError::MissingResource(_) => "OfficeAdapterError::MissingResource",
        OfficeAdapterError::AnchoredObjectTargetMissing(_) => {
            "OfficeAdapterError::AnchoredObjectTargetMissing"
        }
        OfficeAdapterError::SectionIndexMissing(_) => "OfficeAdapterError::SectionIndexMissing",
        OfficeAdapterError::UnresolvedCommentId(_) => "OfficeAdapterError::UnresolvedCommentId",
        OfficeAdapterError::NegativeFootnoteNumber(_) => {
            "OfficeAdapterError::NegativeFootnoteNumber"
        }
        OfficeAdapterError::Canonicalization(_) => "OfficeAdapterError::Canonicalization",
        OfficeAdapterError::InvalidColumnAuthority(_) => {
            "OfficeAdapterError::InvalidColumnAuthority"
        }
    }
}

/// The bucket name for a `ProjectionError` — prefixed `ProjectionError::` (never
/// `OfficeAdapterError::`) so the two fallback stages are distinguishable in the ledger without
/// re-deriving which function raised them.
pub fn projection_error_kind(error: &ProjectionError) -> String {
    match error {
        ProjectionError::Field(name) => format!("ProjectionError::Field({name})"),
        ProjectionError::Malformed(_) => "ProjectionError::Malformed".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_snapshot_round_trip_in_order() {
        clear();
        record("a.docx", "OfficeAdapterError::MasterPagePresent", "detail a");
        record("b.hwp", "OfficeAdapterError::MissingResource", "detail b");
        let entries = snapshot();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].document_name, "a.docx");
        assert_eq!(entries[1].kind, "OfficeAdapterError::MissingResource");
        clear();
        assert!(snapshot().is_empty());
    }

    #[test]
    fn projection_error_kind_names_the_field() {
        let err = ProjectionError::Field("span.column_layout".to_string());
        assert_eq!(
            projection_error_kind(&err),
            "ProjectionError::Field(span.column_layout)"
        );
    }
}
