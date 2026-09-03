//! swift: Render/Office/MasterPagePainter.swift
//! (`applicablePage`), `:73` (the section veto)
//!
//! S5C3-01: the pure arithmetic `MasterPagePainter.applicablePage` does, ported unchanged. The
//! per-object rect arithmetic (`draw(_:onSheet:…)`, `:88-135`) does NOT move — `s5c3.md` "Why the
//! engine answers SELECTION only" — this module answers exactly one question, "which template, if
//! any, applies to this page", the same question `applicablePage` plus the section veto together
//! answer today.

use std::collections::HashSet;
use crate::render::office::office_block::HeaderFooterApplicability;

/// One master-page TEMPLATE, as much of `OfficeMasterPage` as selection needs — its own section
/// and which pages it applies to. The caller's `objects` never cross this boundary (`s5c3.md`
/// API — "Object content and object frames never cross at all").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MasterTemplateDescriptor {
    pub section: i64,
    pub applies_to: HeaderFooterApplicability,
}

/// One VISIBLE page's selection query — `applicablePage`'s own two arguments beyond the template
/// list. `section: None` matches the Swift `nil` fallback: every template is a candidate, not
/// none (`MasterPagePainter.swift:39-41`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MasterPageQuery {
    pub page_index: i64,
    pub section: Option<i64>,
}

/// `MasterPagePainter.applicablePage(_:pageIndex:section:)`, unchanged: filter to the page's own
/// section (or every template, for an unknown section), guard on no candidates, prefer an
/// `.evenPages` template on an even PAGE NUMBER (`pageIndex` is 0-based, so `pageIndex + 1` is the
/// human page — odd index = even page), otherwise the `.defaultPages` one, else the first
/// candidate. Returns the applicable template's INDEX into `templates` (the caller's own array),
/// not a copy of it — `s5c3.md` API: "the applicable template's index into the CALLER'S OWN
/// descriptor array".
pub fn applicable_template_index(
    templates: &[MasterTemplateDescriptor],
    page_index: i64,
    section: Option<i64>,
) -> Option<usize> {
    let candidates: Vec<usize> = match section {
        Some(s) => templates
            .iter()
            .enumerate()
            .filter(|(_, t)| t.section == s)
            .map(|(i, _)| i)
            .collect(),
        None => (0..templates.len()).collect(),
    };
    if candidates.is_empty() {
        return None;
    }
    let is_even_page_number = (page_index + 1) % 2 == 0;
    let parity = if is_even_page_number {
        HeaderFooterApplicability::EvenPages
    } else {
        HeaderFooterApplicability::OddPages
    };
    if let Some(&i) = candidates
        .iter()
        .find(|&&i| templates[i].applies_to == parity)
    {
        return Some(i);
    }
    candidates
        .iter()
        .find(|&&i| templates[i].applies_to == HeaderFooterApplicability::DefaultPages)
        .copied()
        .or_else(|| candidates.first().copied())
}

/// The batched answer `fastdoc_office_master_selection` hands back — one template index (or none)
/// per query, folding `applicable_template_index` together with the section veto
/// (`MasterPagePainter.swift:73`) into the SAME "which template, if any" reply, exactly as
/// `s5c3.md`'s "What moves, what does not" table describes the veto and the selection producing
/// the same per-page answer. The veto only fires when the page's own section is KNOWN
/// (`MasterPagePainter.swift:73` — `if let section, ...`); an unknown section is never vetoed,
/// matching the Swift guard.
pub fn select_master_templates(
    templates: &[MasterTemplateDescriptor],
    vetoed_sections: &HashSet<i64>,
    queries: &[MasterPageQuery],
) -> Vec<Option<usize>> {
    queries
        .iter()
        .map(|query| {
            if let Some(section) = query.section {
                if vetoed_sections.contains(&section) {
                    return None;
                }
            }
            applicable_template_index(templates, query.page_index, query.section)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn template(section: i64, applies_to: HeaderFooterApplicability) -> MasterTemplateDescriptor {
        MasterTemplateDescriptor { section, applies_to }
    }

    fn query(page_index: i64, section: Option<i64>) -> MasterPageQuery {
        MasterPageQuery { page_index, section }
    }

    /// Section filter — a page's section only sees ITS OWN section's templates, `s5c3.md`'s
    /// first branch (`MasterPagePainter.swift:39`). A section-1 page must not resolve to a
    /// section-0-only template even though one exists and would otherwise be `candidates.first`.
    #[test]
    fn section_filter_excludes_other_sections_templates() {
        let templates = [
            template(0, HeaderFooterApplicability::DefaultPages),
            template(1, HeaderFooterApplicability::FirstPage),
        ];
        let index = applicable_template_index(&templates, 0, Some(1));
        assert_eq!(index, Some(1));
    }

    /// Even/odd parity — an `.evenPages` template covers even PAGE NUMBERS, i.e. odd `pageIndex`
    /// (0-based): `pageIndex` 1 is human page 2. An even-index page (human page 1, odd) must fall
    /// through to the default rather than the even template.
    #[test]
    fn even_page_number_prefers_the_even_template() {
        let templates = [
            template(0, HeaderFooterApplicability::DefaultPages),
            template(0, HeaderFooterApplicability::EvenPages),
        ];
        assert_eq!(applicable_template_index(&templates, 1, Some(0)), Some(1),
                   "pageIndex 1 == human page 2, an even page number");
        assert_eq!(applicable_template_index(&templates, 0, Some(0)), Some(0),
                   "pageIndex 0 == human page 1, an odd page number falls back to default");
    }

    /// `nil`-section fallback — a query with no known section matches EVERY template, not none
    /// (`MasterPagePainter.swift:41`).
    #[test]
    fn unknown_section_falls_back_to_every_template() {
        let templates = [
            template(0, HeaderFooterApplicability::DefaultPages),
            template(7, HeaderFooterApplicability::DefaultPages),
        ];
        // Two DefaultPages candidates from different sections; `nil` still resolves to the
        // first, exactly as `candidates.first ?? candidates.first` does when parity doesn't
        // pick an even one and both are DefaultPages.
        assert_eq!(applicable_template_index(&templates, 0, None), Some(0));
    }

    /// Empty-candidates guard — a section with no matching templates yields no template at all,
    /// even though other sections declare some (`MasterPagePainter.swift:43`).
    #[test]
    fn no_candidates_for_the_page_section_yields_none() {
        let templates = [template(0, HeaderFooterApplicability::DefaultPages)];
        assert_eq!(applicable_template_index(&templates, 0, Some(9)), None);
    }

    /// Section veto — a vetoed section yields NO template, whatever it would otherwise resolve
    /// to (`MasterPagePainter.swift:73`).
    #[test]
    fn vetoed_section_yields_no_template() {
        let templates = [template(2, HeaderFooterApplicability::DefaultPages)];
        let vetoed: HashSet<i64> = [2].into_iter().collect();
        let queries = [query(0, Some(2))];
        assert_eq!(select_master_templates(&templates, &vetoed, &queries), vec![None]);
    }

    /// The veto does NOT fire when the page's own section is unknown — the Swift guard is
    /// `if let section, sectionsHidingMasterPage.contains(section)`, so a `nil` section can never
    /// match a vetoed set of concrete section numbers.
    #[test]
    fn vetoed_set_does_not_apply_to_an_unknown_section() {
        let templates = [template(2, HeaderFooterApplicability::DefaultPages)];
        let vetoed: HashSet<i64> = [2].into_iter().collect();
        let queries = [query(0, None)];
        assert_eq!(select_master_templates(&templates, &vetoed, &queries), vec![Some(0)]);
    }
}
