//! The footnote band fixpoint, driven inside the page plan (S5 of
//! `docs/plans/pagination-to-engine.md`; invariants 98, 99).
//!
//! A note is drawn at the foot of the page its marker is cited on, so the band a page reserves
//! depends on which markers land on it, and which markers land on it depends on how much room the
//! band left the body. Both hosts used to run that loop themselves — one layout, one proposal, one
//! stopping-rule call per round — and Avalonia paid an FFI crossing for each round. The plan runs the
//! whole loop in one call: the host reports each note's height, the notes each block cites, and the
//! separator each section declared; this module is the arithmetic around the rule that already
//! exists (`FootnoteBandSettle`), and `page_plan.rs` re-plans between rounds.

use super::footnote_band_settle::FootnoteBandSettle;
use super::page_band_geometry::{FootnoteSeparatorDesc, PageBandGeometry};
use serde::Deserialize;
use std::collections::{BTreeMap, HashMap};

/// One note and how tall the host measured it at the width it is drawn at.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanNote {
    pub number: i64,
    pub height: f64,
}

/// What a section declared about the rule above its notes, in points. A section that declared
/// nothing has no entry here, and the reader's own minimum applies to its pages.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanSeparator {
    pub section: i64,
    #[serde(default)]
    pub line_type: i64,
    #[serde(default)]
    pub line_width: f64,
    #[serde(default)]
    pub margin_top: f64,
    #[serde(default)]
    pub margin_bottom: f64,
    /// The air between two notes of one page.
    #[serde(default)]
    pub note_spacing: f64,
}

/// A note a block cites. `line` is the line of a text block holding the marker; a block with no
/// lines of its own to point at (a table, a picture) is cited from where it starts.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanCite {
    pub note: i64,
    #[serde(default)]
    pub line: Option<u32>,
}

/// Page → the notes it cites, in citation order.
pub type NotesByPage = BTreeMap<u32, Vec<i64>>;

/// Page → the height it reserves.
pub type Bands = HashMap<i64, f64>;

/// The separator a page draws: its own section's, or — when that section said nothing and exactly
/// one section declared one — that one (`DocumentWindowController.footnoteSeparator(forPage:)`).
pub fn separator_for(separators: &[PlanSeparator], section: Option<i64>) -> Option<&PlanSeparator> {
    if separators.is_empty() {
        return None;
    }
    if let Some(s) = section {
        if let Some(own) = separators.iter().find(|p| p.section == s) {
            return Some(own);
        }
    }
    if separators.len() == 1 { separators.first() } else { None }
}

/// What this layout says each page should reserve for the notes it cites — the proposal half of the
/// fixpoint, clamped per page so a note taller than its sheet cannot reserve the sheet out of
/// existence (`DocumentWindowController.proposedNoteBands`).
pub fn propose(
    assignment: &NotesByPage,
    heights: &HashMap<i64, f64>,
    separators: &[PlanSeparator],
    section_of_page: &dyn Fn(u32) -> Option<i64>,
    content_height: f64,
) -> Bands {
    let mut out = Bands::new();
    for (page, numbers) in assignment {
        let drawn: Vec<f64> = numbers.iter().filter_map(|n| heights.get(n).copied()).collect();
        let separator = separator_for(separators, section_of_page(*page));
        let desc = separator.map(|s| FootnoteSeparatorDesc {
            is_declared: true,
            line_type: s.line_type,
            line_width_pt: s.line_width,
            margin_top_pt: s.margin_top,
            margin_bottom_pt: s.margin_bottom,
        });
        let raw = PageBandGeometry::footnote_band_height(
            &drawn,
            PageBandGeometry::separator_allowance(desc.as_ref()),
            separator.map_or(0.0, |s| s.note_spacing),
        );
        let band = FootnoteBandSettle::clamped(raw, content_height);
        if band > 0.0 {
            out.insert(i64::from(*page), band);
        }
    }
    out
}

/// Whether `bands` already reserve what `assignment` needs on every page it names — the guard that
/// lets a re-taken assignment be adopted only when it can never put a note on a page with no room
/// (`DocumentWindowController.refreshFootnoteAssignment`).
pub fn covers(bands: &Bands, need: &Bands) -> bool {
    need.iter().all(|(page, h)| bands.get(page).copied().unwrap_or(0.0) + 0.5 >= *h)
}

/// Equal as states: a page that reserves nothing and a page that is absent are the same.
pub fn same_bands(a: &Bands, b: &Bands) -> bool {
    // Compared bit for bit on purpose: the rule treats a band that moved by any amount as moved.
    let bits = |m: &Bands| m.iter().filter(|(_, v)| **v > 0.0).map(|(k, v)| (*k, v.to_bits())).collect::<BTreeMap<i64, u64>>();
    bits(a) == bits(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn heights(pairs: &[(i64, f64)]) -> HashMap<i64, f64> {
        pairs.iter().copied().collect()
    }

    fn sep(section: i64) -> PlanSeparator {
        PlanSeparator { section, line_type: 1, line_width: 0.5, margin_top: 3.0, margin_bottom: 4.0, note_spacing: 2.0 }
    }

    #[test]
    fn a_page_reserves_its_separator_its_notes_and_the_spacing_between_them() {
        let assignment: NotesByPage = [(2, vec![1, 2])].into_iter().collect();
        let bands = propose(&assignment, &heights(&[(1, 20.0), (2, 30.0)]), &[sep(0)], &|_| Some(0), 400.0);
        // allowance 3 + 0.5 + 4 = 7.5, notes 50, one gap of 2.
        assert_eq!(bands.get(&2).copied(), Some(59.5));
    }

    #[test]
    fn an_undeclared_section_falls_back_to_the_readers_minimum() {
        let assignment: NotesByPage = [(0, vec![1])].into_iter().collect();
        let bands = propose(&assignment, &heights(&[(1, 20.0)]), &[], &|_| Some(0), 400.0);
        assert_eq!(bands.get(&0).copied(), Some(28.0), "the minimum separator allowance is 8");
    }

    #[test]
    fn a_band_never_takes_more_than_three_quarters_of_a_page() {
        let assignment: NotesByPage = [(0, vec![1])].into_iter().collect();
        let bands = propose(&assignment, &heights(&[(1, 10_000.0)]), &[], &|_| None, 400.0);
        assert_eq!(bands.get(&0).copied(), Some(300.0));
    }

    #[test]
    fn a_page_citing_no_measured_note_reserves_nothing() {
        let assignment: NotesByPage = [(0, vec![9])].into_iter().collect();
        assert!(propose(&assignment, &heights(&[(1, 20.0)]), &[sep(0)], &|_| Some(0), 400.0).is_empty());
    }

    #[test]
    fn the_separator_of_a_silent_section_is_the_only_one_declared_or_none() {
        let one = [sep(2)];
        assert_eq!(separator_for(&one, Some(0)).map(|s| s.section), Some(2));
        assert_eq!(separator_for(&one, Some(2)).map(|s| s.section), Some(2));
        let two = [sep(1), sep(2)];
        assert!(separator_for(&two, Some(0)).is_none());
        assert_eq!(separator_for(&two, Some(2)).map(|s| s.section), Some(2));
        assert!(separator_for(&[], Some(0)).is_none());
    }

    #[test]
    fn covers_allows_half_a_point_of_slack_and_names_every_short_page() {
        let have: Bands = [(0, 30.0)].into_iter().collect();
        assert!(covers(&have, &[(0, 30.4)].into_iter().collect()));
        assert!(!covers(&have, &[(0, 31.0)].into_iter().collect()));
        assert!(!covers(&have, &[(1, 5.0)].into_iter().collect()));
    }

    #[test]
    fn bands_of_zero_and_absent_bands_are_the_same_state() {
        let a: Bands = [(0, 10.0), (1, 0.0)].into_iter().collect();
        let b: Bands = [(0, 10.0)].into_iter().collect();
        assert!(same_bands(&a, &b));
        assert!(!same_bands(&a, &[(0, 11.0)].into_iter().collect()));
    }
}
