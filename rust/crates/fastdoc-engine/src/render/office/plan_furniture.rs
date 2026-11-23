//! What a sheet carries besides its body, decided once per page of the plan (S5 of
//! `docs/plans/pagination-to-engine.md`): which running head and foot it shows, which master page
//! sits behind it, and the page number it prints.
//!
//! Both hosts used to decide these themselves from where marked text landed — macOS in
//! `PageBandPainter.applicableEntry` and `DocumentWindowController.displayedPageNumber`, Avalonia in
//! `HeaderFooterText.SelectChosen` and `PageNumberFacts` — and the two disagreed (Avalonia opened a
//! section's first page with its first-page head; macOS opens only the document's first page with it).
//! The rules here are macOS's, which is the reference (invariants 62, 77, 78, 189). They are pure
//! functions over the page's section and index; the host supplies the entries it holds (an opaque
//! position in its own list comes back) and never decides which one applies.

use super::master_page_selection::{select_master_templates, MasterPageQuery, MasterTemplateDescriptor};
use super::office_block::HeaderFooterApplicability;
use serde::Deserialize;
use std::collections::{BTreeMap, HashSet};

/// Which pages an entry covers — `HeaderFooterApplicability` in the tree's own spelling.
pub type PlanApplies = HeaderFooterApplicability;

/// One running head, foot or master page as the host holds it: when it applies, and the one section
/// it belongs to (`None`: it applies wherever its parity does, as every docx and odt entry does).
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanEntry {
    pub applies_to: PlanApplies,
    #[serde(default)]
    pub section: Option<i64>,
}

/// `PageBandPainter.applicableEntry`, unchanged: the section's own veto first, then the entries of
/// the page's own section (and the ones that name none), then the document's FIRST page's first-page
/// entry, then the page's own parity, then the catch-all. Returns the position in `entries`.
///
/// The first-page entry is the DOCUMENT's first page, not each section's: an entry that wanted a
/// section's opening page would show on every section start, which is what macOS never did.
pub fn applicable_entry(
    entries: &[PlanEntry],
    page_index: i64,
    section: Option<i64>,
    hiding: &HashSet<i64>,
) -> Option<usize> {
    if let Some(s) = section {
        if hiding.contains(&s) {
            return None;
        }
    }
    let own = |e: &PlanEntry| match section {
        Some(s) => e.section.is_none() || e.section == Some(s),
        None => true,
    };
    let find = |applies: PlanApplies| entries.iter().position(|e| own(e) && e.applies_to == applies);
    if page_index == 0 {
        if let Some(first) = find(PlanApplies::FirstPage) {
            return Some(first);
        }
    }
    let parity = if (page_index + 1) % 2 == 0 { PlanApplies::EvenPages } else { PlanApplies::OddPages };
    find(parity).or_else(|| find(PlanApplies::DefaultPages))
}

/// The page number each page SHOWS. Without a restart that is `page + 1`; with one it is the
/// restart's number plus the page's distance from the most recent restart at or before it, so a
/// document that renumbers its body does not renumber its front matter backwards
/// (`DocumentWindowController.displayedPageNumber`).
pub fn displayed_numbers(page_count: u32, restarts: &BTreeMap<u32, i64>) -> Vec<i64> {
    (0..page_count)
        .map(|page| match restarts.range(..=page).next_back() {
            Some((anchor, first)) => first + i64::from(page - anchor),
            None => i64::from(page) + 1,
        })
        .collect()
}

/// The master page behind each page: `MasterPagePainter.applicablePage` plus the section veto,
/// answered by the one function the engine already exports (`fastdoc_office_master_selection`).
pub fn master_pages(
    masters: &[PlanEntry],
    hiding: &HashSet<i64>,
    pages: &[(u32, Option<i64>)],
) -> Vec<Option<usize>> {
    if masters.is_empty() {
        return vec![None; pages.len()];
    }
    let templates: Vec<MasterTemplateDescriptor> = masters
        .iter()
        .map(|m| MasterTemplateDescriptor { section: m.section.unwrap_or(0), applies_to: m.applies_to })
        .collect();
    let queries: Vec<MasterPageQuery> = pages
        .iter()
        .map(|(page, section)| MasterPageQuery { page_index: i64::from(*page), section: *section })
        .collect();
    select_master_templates(&templates, hiding, &queries)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(applies_to: PlanApplies, section: Option<i64>) -> PlanEntry {
        PlanEntry { applies_to, section }
    }

    fn none() -> HashSet<i64> {
        HashSet::new()
    }

    #[test]
    fn the_first_page_entry_belongs_to_the_documents_first_page_only() {
        let entries = [
            entry(PlanApplies::DefaultPages, None),
            entry(PlanApplies::FirstPage, None),
        ];
        assert_eq!(applicable_entry(&entries, 0, Some(0), &none()), Some(1));
        // A later section's opening page is not the document's: it takes the ordinary entry.
        assert_eq!(applicable_entry(&entries, 5, Some(1), &none()), Some(0));
    }

    #[test]
    fn a_pages_parity_wins_over_the_catch_all_and_page_numbers_count_from_one() {
        let entries = [
            entry(PlanApplies::DefaultPages, None),
            entry(PlanApplies::EvenPages, None),
        ];
        // Page index 1 is page 2: an even number.
        assert_eq!(applicable_entry(&entries, 1, None, &none()), Some(1));
        assert_eq!(applicable_entry(&entries, 2, None, &none()), Some(0));
    }

    #[test]
    fn an_entry_of_another_section_never_applies_but_one_naming_no_section_always_does() {
        let entries = [
            entry(PlanApplies::DefaultPages, Some(1)),
            entry(PlanApplies::DefaultPages, None),
        ];
        assert_eq!(applicable_entry(&entries, 3, Some(0), &none()), Some(1));
        assert_eq!(applicable_entry(&entries, 3, Some(1), &none()), Some(0));
        let only_other = [entry(PlanApplies::DefaultPages, Some(1))];
        assert_eq!(applicable_entry(&only_other, 3, Some(0), &none()), None);
        // A page whose section is not known sees every entry.
        assert_eq!(applicable_entry(&only_other, 3, None, &none()), Some(0));
    }

    #[test]
    fn a_section_that_hides_its_running_head_shows_none() {
        let entries = [entry(PlanApplies::DefaultPages, None)];
        let hiding: HashSet<i64> = [2].into_iter().collect();
        assert_eq!(applicable_entry(&entries, 7, Some(2), &hiding), None);
        assert_eq!(applicable_entry(&entries, 7, Some(1), &hiding), Some(0));
    }

    #[test]
    fn a_page_with_no_matching_entry_shows_nothing() {
        let entries = [entry(PlanApplies::FirstPage, None)];
        assert_eq!(applicable_entry(&entries, 4, Some(0), &none()), None);
    }

    #[test]
    fn numbers_count_from_the_most_recent_restart_and_front_matter_keeps_its_own() {
        let restarts: BTreeMap<u32, i64> = [(3, 1), (6, 10)].into_iter().collect();
        assert_eq!(displayed_numbers(8, &restarts), vec![1, 2, 3, 1, 2, 3, 10, 11]);
        assert_eq!(displayed_numbers(3, &BTreeMap::new()), vec![1, 2, 3]);
    }

    #[test]
    fn master_pages_follow_the_engines_selection_rule() {
        let masters = [
            entry(PlanApplies::DefaultPages, Some(0)),
            entry(PlanApplies::EvenPages, Some(0)),
            entry(PlanApplies::DefaultPages, Some(1)),
        ];
        let hiding: HashSet<i64> = [1].into_iter().collect();
        let answers = master_pages(&masters, &hiding, &[(0, Some(0)), (1, Some(0)), (2, Some(1)), (3, Some(2))]);
        assert_eq!(answers, vec![Some(0), Some(1), None, None]);
        assert_eq!(master_pages(&[], &none(), &[(0, Some(0))]), vec![None]);
    }
}
