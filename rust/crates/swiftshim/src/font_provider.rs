//! The one place the engine asks a question only a font system can answer.
//!
//! Everything else in this crate is a value: a colour is four numbers, a rect is four numbers, a
//! paragraph style is the numbers the document declared. Fonts are not. Three of the questions the
//! readers ask have no answer inside the engine —
//!
//!   * is there a font called "함초롬바탕" on this machine?
//!   * what do you get when you add `.bold` to THAT face?
//!   * what is the system UI font here?
//!
//! — and the second one is the reason this is a port rather than a lookup table. AppKit's answer
//! is not "the same family, bolder". `FontSubstitutionResolver.swift` records the measurement:
//! adding `.bold` to an already-`-SemiBold` substitute returned `.AppleKoreanFont-Bold`, a
//! DIFFERENT face, and adding `[.bold, .italic]` to a `-Regular` one silently did nothing. A
//! descriptor there is an opaque handle into a cascade, not a struct anyone can recompose, so a
//! Rust type modelling it as `{family, traits}` and composing deterministically would quietly
//! choose different faces than macOS on exactly the Korean documents this reader exists for.
//!
//! Hence `FaceId`: the engine carries an identity the provider issued and hands it back to ask
//! what it means. The engine never invents one.
//!
//! WHO IMPLEMENTS THIS IS AN OPEN PRODUCT DECISION, and both answers are legitimate:
//!
//!   host-owned    the platform's own font system answers. macOS reproduces the shipped reader
//!                 exactly; two platforms can choose different faces for the same document.
//!   engine-owned  the engine answers from a bundled face set and rhwp's metric table. Every
//!                 platform reproduces the same document identically; macOS output moves away
//!                 from the shipped reader.
//!
//! `docs/CROSS-PLATFORM.md` §6 leaves the metric half of this open ("폰트 메트릭의 권위"). This is
//! the same fork one step earlier — which face, before how wide. The boundary is the same either
//! way, which is why it can be built before the fork is settled: only the implementation moves.

use crate::color_font::{NSFontDescriptorSymbolicTraits, NSFontWeight};

/// A face, as whoever resolved it names it. Opaque ON PURPOSE — see this module's header.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct FaceId(pub u64);

/// What a resolved face turns out to be. The engine reads these to fill an `NSFont`'s fields; it
/// never uses them to reconstruct a face, which is what makes the opacity hold.
#[derive(Debug, Clone, PartialEq)]
pub struct FaceInfo {
    /// swift: `NSFont.fontName` — the POSTSCRIPT name (`AppleSDGothicNeo-SemiBold`).
    pub name: String,
    /// swift: `NSFont.familyName` — nil for the private system-UI cascades.
    pub family: Option<String>,
    pub traits: NSFontDescriptorSymbolicTraits,
}

/// swift: the parts of AppKit/CoreText the readers actually consult.
pub trait FontProvider: Send + Sync {
    /// swift: `NSFont(name:size:)` — `None` when this machine has no such font, which is the
    /// signal `FontSubstitutionResolver` branches on. Size is not passed: a face's identity does
    /// not depend on the size it is asked for, and every call site immediately re-sizes anyway.
    fn face_named(&self, name: &str) -> Option<FaceId>;

    /// swift: `NSFont(descriptor:size:)` — resolve a descriptor that may be a face with traits
    /// layered on top, features layered on top, or nothing but traits.
    ///
    /// Implementations MUST NOT assume "same family, plus traits". Ask the font system.
    fn resolve(&self, descriptor: &crate::color_font::NSFontDescriptor) -> Option<FaceId>;

    /// swift: `NSFont.systemFont(ofSize:weight:)` / `.monospacedSystemFont(ofSize:weight:)`.
    /// Not a query — the system always has these — so it does not return `Option`.
    fn system_face(&self, weight: NSFontWeight, monospaced: bool) -> FaceId;

    /// What a `FaceId` this provider issued actually is.
    fn describe(&self, face: FaceId) -> FaceInfo;
}

static PROVIDER: std::sync::OnceLock<Box<dyn FontProvider>> = std::sync::OnceLock::new();

/// Declares the font world this process runs in. Call once, before any typography is built.
///
/// Returns whether it took; a second call is ignored rather than swapped, because a provider
/// change mid-run would make two halves of one document resolve against different font worlds.
pub fn install(provider: Box<dyn FontProvider>) -> bool {
    PROVIDER.set(provider).is_ok()
}

/// The installed provider.
///
/// Panics when none is installed, and that is the design. The two "safe" defaults are both
/// silently wrong: a provider that says every font exists never substitutes, and one that says
/// none does substitutes everything — and either way the document renders, plausibly, with the
/// wrong typefaces and nothing reports it. Failing loudly at the boundary is the same call this
/// port already made about placeholder stand-ins.
pub fn provider() -> &'static dyn FontProvider {
    PROVIDER
        .get()
        .map(|b| b.as_ref())
        .expect("no FontProvider installed — call swiftshim::font_provider::install() first")
}

/// Whether a provider has been installed, for callers that must not panic (probes, tests).
pub fn is_installed() -> bool {
    PROVIDER.get().is_some()
}
