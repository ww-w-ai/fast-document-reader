//! S2A2 Pass C, unit C1 — measures, before anything is built on it, whether a column position
//! is derivable from this crate's HWP model, across a real HWP corpus. Two independent
//! measurements, run by two `#[ignore]`d tests sharing this file (positional keying's own
//! findings killed it — see below — so the second test measures its value-based replacement):
//!
//! - `column_position_keys_agree_between_the_raw_and_json_walks` (`FMD_HWP_COLUMN_KEY_PARITY`) —
//!   whether `(section_index, paragraph_index, control_ordinal_within_paragraph)` is derivable
//!   identically from rhwp's raw model and the flat JSON envelope. Three checks (key sets can
//!   agree by coincidence — see `column_key_parity.rs`'s doc comment): key-set equality, CHECK A
//!   (per-section paragraph-count parity, run unconditionally), CHECK B (per-shared-key field
//!   corroboration). VERDICT: DISAGREES — `push_shape_blocks` flattens a text box's paragraphs
//!   into the top-level block list as SIBLING `Block::Para` entries and the footnote path inserts
//!   a synthetic `Block::Para`, so `paragraph_index` drifts in ~20% of the corpus. Positional
//!   keying is dead.
//! - `value_based_reconciliation_ambiguity_rate` (`FMD_HWP_COLUMN_AMBIGUITY`) — positional
//!   keying's replacement: reconcile by VALUE instead. Pools every raw `ColumnDef` occurrence
//!   (body + nested), groups by the ten-field signature the JSON DTO shares with the raw
//!   declaration, and measures how often that signature fails to discriminate — i.e. how often a
//!   JSON occurrence's own signature would resolve to more than one `(column_type, raw_attr)`
//!   answer in the raw pool.
//!
//! Both ignored by default (a real corpus this repo does not ship). Run explicitly:
//!
//! ```text
//! FMD_HWP_COLUMN_KEY_PARITY=<dir> \
//!     cargo test -p fastdoc-engine --test hwp_column_key_parity -- --ignored --nocapture
//! FMD_HWP_COLUMN_AMBIGUITY=<dir> \
//!     cargo test -p fastdoc-engine --test hwp_column_key_parity -- --ignored --nocapture
//! ```

use fastdoc_engine::render::office::hwp_reader::column_key_parity::{
    compute_column_ambiguity, compute_column_key_parity,
};

#[test]
#[ignore = "requires an explicit external HWP/HWPX corpus"]
fn column_position_keys_agree_between_the_raw_and_json_walks() {
    let Some(dir) = std::env::var("FMD_HWP_COLUMN_KEY_PARITY").ok().filter(|d| !d.is_empty())
    else {
        panic!("set FMD_HWP_COLUMN_KEY_PARITY=<dir> before running this ignored corpus probe");
    };

    let mut files = Vec::new();
    collect(std::path::Path::new(&dir), &mut files);
    files.sort();
    assert!(!files.is_empty(), "FMD_HWP_COLUMN_KEY_PARITY matched no .hwp/.hwpx under {dir}");

    let mut scanned = 0usize;
    let mut parse_failures: Vec<String> = Vec::new();
    let mut declares_column = 0usize;
    let mut full_agreement = 0usize;
    let mut nested_total = 0usize;
    let mut multi_column_candidates: Vec<String> = Vec::new();
    let mut disagreements: Vec<String> = Vec::new();

    // CHECK A — per-section paragraph-count parity, aggregated across every file (not gated on
    // that file declaring a column at all).
    let mut check_a_files_matched = 0usize;
    let mut check_a_files_mismatched = 0usize;
    let mut check_a_worst: Vec<(usize, String)> = Vec::new(); // (mismatch count, detail)

    // CHECK B — per-shared-key field corroboration.
    let mut check_b_keys_compared = 0usize;
    let mut check_b_keys_corroborated = 0usize;
    let mut check_b_mismatches: Vec<String> = Vec::new();

    for path in &files {
        scanned += 1;
        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(e) => {
                parse_failures.push(format!("{} — could not read file: {e}", path.display()));
                continue;
            }
        };

        let parity = match compute_column_key_parity(&bytes) {
            Ok(p) => p,
            Err(e) => {
                parse_failures.push(format!("{} — {e}", path.display()));
                continue;
            }
        };

        nested_total += parity.nested_column_def_count;

        // --- key-set comparison ---
        let raw_only: Vec<_> = parity.raw_keys.difference(&parity.json_keys).collect();
        let json_only: Vec<_> = parity.json_keys.difference(&parity.raw_keys).collect();

        if !parity.raw_keys.is_empty() || !parity.json_keys.is_empty() {
            declares_column += 1;
        }
        if parity.raw_keys.len() >= 2 {
            multi_column_candidates.push(path.display().to_string());
        }

        if raw_only.is_empty() && json_only.is_empty() {
            full_agreement += 1;
        } else {
            let mut raw_only_sorted: Vec<_> = raw_only.iter().map(|k| format!("{k:?}")).collect();
            let mut json_only_sorted: Vec<_> = json_only.iter().map(|k| format!("{k:?}")).collect();
            raw_only_sorted.sort();
            json_only_sorted.sort();
            disagreements.push(format!(
                "{} — raw_only={:?} json_only={:?} raw_n={} json_n={}",
                path.display(),
                raw_only_sorted,
                json_only_sorted,
                parity.raw_keys.len(),
                parity.json_keys.len(),
            ));
        }

        // --- CHECK A ---
        let mismatched_sections: Vec<_> = parity
            .section_paragraph_counts
            .iter()
            .filter(|s| !s.matches())
            .collect();
        if mismatched_sections.is_empty() {
            check_a_files_matched += 1;
        } else {
            check_a_files_mismatched += 1;
            let detail = format!(
                "{} — {}",
                path.display(),
                mismatched_sections
                    .iter()
                    .map(|s| format!(
                        "section {}: raw={:?} json={:?}",
                        s.section_index, s.raw_count, s.json_count
                    ))
                    .collect::<Vec<_>>()
                    .join("; ")
            );
            check_a_worst.push((mismatched_sections.len(), detail));
        }

        // --- CHECK B ---
        check_b_keys_compared += parity.key_corroborations.len();
        for kc in &parity.key_corroborations {
            if kc.mismatched_fields.is_empty() {
                check_b_keys_corroborated += 1;
            } else {
                check_b_mismatches.push(format!(
                    "{} — key={:?} fields={:?}",
                    path.display(),
                    kc.key,
                    kc.mismatched_fields
                ));
            }
        }
    }

    check_a_worst.sort_by(|a, b| b.0.cmp(&a.0));
    check_a_worst.truncate(10);

    println!(
        "HWP_COLUMN_KEY_PARITY scanned={} parse_failures={} declares_column={} full_agreement={} disagreeing={} nested_column_def_total={}",
        scanned,
        parse_failures.len(),
        declares_column,
        full_agreement,
        disagreements.len(),
        nested_total,
    );
    println!(
        "HWP_COLUMN_KEY_PARITY multi_column_candidates={}",
        multi_column_candidates.join(", ")
    );
    println!(
        "HWP_COLUMN_KEY_PARITY CHECK_A files_matched={} files_mismatched={}",
        check_a_files_matched, check_a_files_mismatched
    );
    println!(
        "HWP_COLUMN_KEY_PARITY CHECK_B keys_compared={} keys_corroborated={} keys_mismatched={}",
        check_b_keys_compared,
        check_b_keys_corroborated,
        check_b_mismatches.len()
    );
    if !parse_failures.is_empty() {
        println!("HWP_COLUMN_KEY_PARITY parse_failure_detail:");
        for f in &parse_failures {
            println!("  {f}");
        }
    }
    if !disagreements.is_empty() {
        println!("HWP_COLUMN_KEY_PARITY disagreement_detail:");
        for d in &disagreements {
            println!("  {d}");
        }
    }
    if !check_a_worst.is_empty() {
        println!("HWP_COLUMN_KEY_PARITY CHECK_A worst_offenders (top 10 by mismatched section count):");
        for (_, detail) in &check_a_worst {
            println!("  {detail}");
        }
    }
    if !check_b_mismatches.is_empty() {
        println!("HWP_COLUMN_KEY_PARITY CHECK_B mismatch_detail:");
        for m in &check_b_mismatches {
            println!("  {m}");
        }
    }
}

#[test]
#[ignore = "requires an explicit external HWP/HWPX corpus"]
fn value_based_reconciliation_ambiguity_rate() {
    let Some(dir) = std::env::var("FMD_HWP_COLUMN_AMBIGUITY").ok().filter(|d| !d.is_empty()) else {
        panic!("set FMD_HWP_COLUMN_AMBIGUITY=<dir> before running this ignored corpus probe");
    };

    let mut files = Vec::new();
    collect(std::path::Path::new(&dir), &mut files);
    files.sort();
    assert!(!files.is_empty(), "FMD_HWP_COLUMN_AMBIGUITY matched no .hwp/.hwpx under {dir}");

    let mut scanned = 0usize;
    let mut parse_failures: Vec<String> = Vec::new();

    // Corpus totals — "all" = body + nested raw pool (the replacement design's actual scope).
    let (mut all_occurrences, mut all_ambiguous_occurrences) = (0usize, 0usize);
    let (mut all_distinct_signatures, mut all_resolvable_signatures, mut all_ambiguous_signatures) =
        (0usize, 0usize, 0usize);

    // Same totals, body-only raw pool — so the coordinator can see whether nested declarations
    // help or hurt discrimination.
    let (mut body_occurrences, mut body_ambiguous_occurrences) = (0usize, 0usize);
    let (mut body_distinct_signatures, mut body_resolvable_signatures, mut body_ambiguous_signatures) =
        (0usize, 0usize, 0usize);

    let (mut json_total, mut json_unmatched) = (0usize, 0usize);
    let mut unmatched_files: Vec<String> = Vec::new();

    // Per-file ambiguous-occurrence count (all-scope), for "files with the most ambiguity".
    let mut per_file_ambiguity: Vec<(usize, usize, String)> = Vec::new(); // (ambiguous_occ, ambiguous_sig, path)

    for path in &files {
        scanned += 1;
        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(e) => {
                parse_failures.push(format!("{} — could not read file: {e}", path.display()));
                continue;
            }
        };

        let report = match compute_column_ambiguity(&bytes) {
            Ok(r) => r,
            Err(e) => {
                parse_failures.push(format!("{} — {e}", path.display()));
                continue;
            }
        };

        all_occurrences += report.all.occurrences;
        all_ambiguous_occurrences += report.all.ambiguous_occurrences;
        all_distinct_signatures += report.all.distinct_signatures;
        all_resolvable_signatures += report.all.resolvable_signatures;
        all_ambiguous_signatures += report.all.ambiguous_signatures;

        body_occurrences += report.body_only.occurrences;
        body_ambiguous_occurrences += report.body_only.ambiguous_occurrences;
        body_distinct_signatures += report.body_only.distinct_signatures;
        body_resolvable_signatures += report.body_only.resolvable_signatures;
        body_ambiguous_signatures += report.body_only.ambiguous_signatures;

        json_total += report.json_occurrences_total;
        json_unmatched += report.json_occurrences_unmatched;
        if report.json_occurrences_unmatched > 0 {
            unmatched_files.push(format!(
                "{} — unmatched={} of {}",
                path.display(),
                report.json_occurrences_unmatched,
                report.json_occurrences_total
            ));
        }

        if report.all.ambiguous_occurrences > 0 {
            per_file_ambiguity.push((
                report.all.ambiguous_occurrences,
                report.all.ambiguous_signatures,
                path.display().to_string(),
            ));
        }
    }

    per_file_ambiguity.sort_by(|a, b| b.0.cmp(&a.0));
    per_file_ambiguity.truncate(15);

    let all_share = if all_occurrences > 0 {
        all_ambiguous_occurrences as f64 / all_occurrences as f64
    } else {
        0.0
    };
    let body_share = if body_occurrences > 0 {
        body_ambiguous_occurrences as f64 / body_occurrences as f64
    } else {
        0.0
    };

    println!(
        "HWP_COLUMN_AMBIGUITY scanned={} parse_failures={} all_occurrences={} all_distinct_signatures={} all_resolvable_signatures={} all_ambiguous_signatures={} all_ambiguous_occurrences={} all_ambiguous_share={:.4}",
        scanned,
        parse_failures.len(),
        all_occurrences,
        all_distinct_signatures,
        all_resolvable_signatures,
        all_ambiguous_signatures,
        all_ambiguous_occurrences,
        all_share,
    );
    println!(
        "HWP_COLUMN_AMBIGUITY body_only_occurrences={} body_only_distinct_signatures={} body_only_resolvable_signatures={} body_only_ambiguous_signatures={} body_only_ambiguous_occurrences={} body_only_ambiguous_share={:.4}",
        body_occurrences,
        body_distinct_signatures,
        body_resolvable_signatures,
        body_ambiguous_signatures,
        body_ambiguous_occurrences,
        body_share,
    );
    println!(
        "HWP_COLUMN_AMBIGUITY json_occurrences_total={} json_occurrences_unmatched={} json_unmatched_files={}",
        json_total,
        json_unmatched,
        unmatched_files.len(),
    );
    if !parse_failures.is_empty() {
        println!("HWP_COLUMN_AMBIGUITY parse_failure_detail:");
        for f in &parse_failures {
            println!("  {f}");
        }
    }
    if !per_file_ambiguity.is_empty() {
        println!("HWP_COLUMN_AMBIGUITY worst_offenders (top 15 by ambiguous occurrence count, all-scope):");
        for (occ, sig, path) in &per_file_ambiguity {
            println!("  {path} — ambiguous_occurrences={occ} ambiguous_signatures={sig}");
        }
    }
    if !unmatched_files.is_empty() {
        println!("HWP_COLUMN_AMBIGUITY unmatched_json_detail:");
        for f in &unmatched_files {
            println!("  {f}");
        }
    }
}

fn collect(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect(&path, out);
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            let ext = ext.to_ascii_lowercase();
            if ext == "hwp" || ext == "hwpx" {
                out.push(path);
            }
        }
    }
}
