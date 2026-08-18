import Foundation
import CoreGraphics

/// WHEN TO STOP RE-TYPESETTING a document whose notes and whose page boundaries each depend on the
/// other.
///
/// The coupling, stated once: a note is drawn at the foot of the page its marker is CITED on, so
/// the band a page reserves is a function of which markers landed there — and which markers land
/// there is a function of how much room the band left the body. That is a fixpoint, not a
/// reservation, and it is why S14 may not simply measure the notes and reserve their height.
///
/// This type owns ONLY the stopping rule. It reserves nothing, measures nothing and draws nothing:
/// it is handed the band vector a round proposed and the vectors every earlier round proposed, and
/// answers whether to accept it, run again, or stop with a stated one. Keeping it free of layout is
/// what lets the pathological cases be tested without a document — see `FootnoteBandSettleTests`.
///
/// ## Why a plain "run until nothing moves" is not enough
///
/// The existing settle loop (`DocumentWindowController.finishWalk` → `settlePagedTables`, capped at
/// `maxPagedTableSettles` = 8) already re-runs a walk whenever a table moved, and its termination
/// argument is that a table pushed to a page top declines to move again — monotone, so it settles.
/// A note band has no such argument available, because the two directions genuinely fight:
///
/// - a band that GROWS pushes the body up, so a marker near the foot moves to the next page, so the
///   band that grew now has one fewer note and SHRINKS;
/// - a band that shrank lets the marker back, and it grows again.
///
/// That is a 2-cycle, and it is reachable with one note on one page. A loop that waits for
/// stillness would spin until the cap and then take whichever half of the oscillation it happened
/// to stop on — which is the half that can be WRONG, because one of the two states has a note whose
/// page reserved no room for it. So the rule below detects the repeat rather than waiting it out,
/// and resolves it in a stated direction.
///
/// ## The direction, and why it is up
///
/// Ties and cycles are resolved by taking the POINTWISE MAXIMUM over the states seen. Reserving too
/// much leaves a page with a gap above its notes; reserving too little puts a note where the body
/// already is. A gap is wrong by a measurable amount and stays inside the sheet; an overlap is two
/// things drawn on top of each other. Between a layout that is loose and one that is corrupt, the
/// loose one is the only one that can be shipped, so `max` is the safe half of every oscillation.
///
/// ## Termination
///
/// Three independent stops, checked in this order, so the loop provably ends:
///
/// 1. **Stillness** — the proposal equals the last one. Nothing is moving; accept it.
/// 2. **Repeat** — the proposal equals ANY earlier one. The sequence is deterministic (the same
///    band vector re-typesets to the same layout), so a repeat means the remainder is a cycle and
///    running longer cannot produce a state that is not already in hand. Stop on the cycle's max.
/// 3. **Cap** — the caller's round budget. The backstop for a sequence that neither settles nor
///    repeats within it, which the clamp below makes finite but not necessarily short.
///
/// The clamp is what makes any of that bounded at all: without it a note taller than the page it is
/// cited on reserves the whole page, leaves the body nowhere to go, and every round pushes the same
/// marker one page further forever.
enum FootnoteBandSettle {

    /// How many times one render may re-solve its layout — the SHARED round budget of the settle
    /// loop this rule runs inside (`DocumentWindowController.maxPagedTableSettles` is defined as
    /// this). Held here, in the rule that actually needs a bound, rather than beside the loop: the
    /// table settle terminates on its own and treats the cap as a backstop, while a note band can
    /// genuinely cycle and is stopped BY it.
    ///
    /// MEASURED (roadmap, S13 research): a settle round costs roughly 38 ms on the reference
    /// document, so eight is about 300 ms of worst case — the budget that already ships.
    static let maxRounds = 8

    /// The most of a page's body a note band may take, as a fraction of that page's own content
    /// height.
    ///
    /// This is a TERMINATION guard, not a typesetting judgement. Its whole job is to keep the body
    /// height positive so a marker cannot be pushed forward forever by a band that consumed the
    /// page it was going to land on. What actually happens to a note too tall for the room left —
    /// splitting it across pages, the way Word does — is S15's, and when that lands this clamp
    /// stops being reachable rather than becoming wrong.
    static let maxBandFraction: CGFloat = 0.75

    /// A proposed band, made safe to lay out with: never negative, never more than
    /// `maxBandFraction` of the page it sits on.
    /// A `nan` reserves nothing — it carries no measurement at all, so there is nothing to honour.
    /// An INFINITE band clamps like any other oversized one rather than falling to zero: it means
    /// "taller than anything", and zero is the unsafe half of that (a note drawn over the body),
    /// which would put the one value most likely to arrive from a broken measurement on exactly the
    /// side this type exists to avoid.
    static func clamped(_ raw: CGFloat, pageContentHeight: CGFloat) -> CGFloat {
        guard pageContentHeight > 0, !raw.isNaN, raw > 0 else { return 0 }
        return min(raw, pageContentHeight * maxBandFraction)
    }

    /// Why the loop stopped, carried so a caller can log or test the reason rather than infer it.
    enum StopReason: Equatable {
        /// Two consecutive rounds proposed the same bands.
        case still
        /// A proposal repeated one from an earlier round — the remainder is a cycle.
        case cycle
        /// The caller's round budget ran out.
        case cap
    }

    /// What the caller should do with the round it just finished.
    enum Outcome: Equatable {
        /// Lay out once more with these bands.
        case retry([Int: CGFloat])
        /// These bands are final; stop.
        case stop([Int: CGFloat], StopReason)
    }

    /// The stopping rule.
    ///
    /// - Parameters:
    ///   - proposed: the bands the round that just finished asks for, keyed by page. A page absent
    ///     from the dictionary reserves nothing, which is the same thing as a `0` entry — compared
    ///     as such, so a round that drops a key rather than zeroing it is not read as a change.
    ///   - history: every earlier proposal, oldest first. The caller appends; this never mutates.
    ///   - cap: the round budget, matching the settle loop's own (`maxPagedTableSettles`).
    static func step(proposed: [Int: CGFloat], history: [[Int: CGFloat]], cap: Int) -> Outcome {
        let now = normalised(proposed)
        let seen = history.map(normalised)
        if let last = seen.last, last == now { return .stop(now, .still) }
        if let first = seen.firstIndex(of: now) {
            // Everything from the repeat's first appearance onward IS the cycle — the states
            // between the two sightings are exactly the ones it will keep visiting.
            return .stop(pointwiseMax(Array(seen[first...]) + [now]), .cycle)
        }
        guard seen.count + 1 < cap else { return .stop(pointwiseMax(seen + [now]), .cap) }
        return .retry(now)
    }

    /// The largest band each page was asked for across these states — the safe half of an
    /// oscillation (see the type comment).
    static func pointwiseMax(_ states: [[Int: CGFloat]]) -> [Int: CGFloat] {
        var out: [Int: CGFloat] = [:]
        for state in states {
            for (page, band) in state where band > 0 {
                out[page] = Swift.max(out[page] ?? 0, band)
            }
        }
        return out
    }

    /// Drops the entries that reserve nothing, so "absent" and "zero" are the same state. Without
    /// this a round that stopped citing a note on a page would look like a change forever, and the
    /// repeat check would never fire.
    private static func normalised(_ state: [Int: CGFloat]) -> [Int: CGFloat] {
        state.filter { $0.value > 0 }
    }
}
