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

    /// swift: `CTFontGetGlyphsForCharacters` — can this face draw this scalar?
    ///
    /// A cmap lookup, and the reason `FontSubstitutionResolver` exists: a face that cannot draw a
    /// character must be replaced BEFORE the run is built, or the reader paints tofu. Not derivable
    /// from a family name, so it belongs here with the other three.
    fn covers(&self, face: FaceId, scalar: u32) -> bool;

    /// swift: `CTFontCreateForString` — what the font system itself would substitute for a scalar
    /// this face cannot draw.
    ///
    /// `None` when the system offers nothing, which the caller reads as "keep the declared face".
    /// Deliberately not "pick from a list we hold": the substitution cascade is the platform's, and
    /// reproducing this build means asking it rather than modelling it.
    fn substitute(&self, declared: FaceId, scalar: u32) -> Option<FaceId>;
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

// ---------------------------------------------------------------------------------------------
// A provider the HOST answers, reached through plain C function pointers.
//
// `host-owned` was chosen for the fork this module's header describes: the platform's own font
// system answers, so this build reproduces the shipped macOS reader exactly and the corpus
// comparison against it means something. The other fork (a bundled face set, identical on every
// platform) can be a second implementation of the same trait — that is why the boundary was worth
// having before the fork was settled.
//
// A `FaceId` is issued by the host and opaque here, exactly as the trait requires. This crate never
// constructs one, never decomposes one, and never assumes two faces with the same traits are the
// same face.
// ---------------------------------------------------------------------------------------------

/// The four questions, as C function pointers. `0` is the null `FaceId` — "no such face" — which
/// is why the host must never issue `0` for a real one.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct FontProviderCallbacks {
    /// `NSFont(name:size:)` — returns 0 when this machine has no such face.
    pub face_named: extern "C" fn(name: *const std::os::raw::c_char) -> u64,
    /// `NSFont(descriptor:size:)`. `base` is 0 when the descriptor names no face of its own.
    /// `features` is `feature_count` pairs of (key, value), flattened.
    pub resolve: extern "C" fn(
        base: u64,
        traits: u32,
        features: *const i64,
        feature_count: usize,
    ) -> u64,
    /// `NSFont.systemFont(ofSize:weight:)` / `.monospacedSystemFont(...)`. Never 0.
    pub system_face: extern "C" fn(weight: f64, monospaced: bool) -> u64,
    /// Fills `name`/`family` (NUL-terminated, truncated to the given capacities) and `traits`.
    /// `has_family` is false for the private system-UI cascades, whose `familyName` is nil.
    pub describe: extern "C" fn(
        face: u64,
        name: *mut std::os::raw::c_char,
        name_cap: usize,
        family: *mut std::os::raw::c_char,
        family_cap: usize,
        has_family: *mut bool,
        traits: *mut u32,
    ),
    /// `CTFontGetGlyphsForCharacters` — can this face draw this scalar?
    pub covers: extern "C" fn(face: u64, scalar: u32) -> bool,
    /// `CTFontCreateForString` — what the system substitutes, or 0 for "nothing to offer".
    pub substitute: extern "C" fn(declared: u64, scalar: u32) -> u64,
}

// SAFETY: the callbacks are plain function pointers into host code that is itself thread-safe
// (AppKit font lookup is), and this struct holds no state of its own.
unsafe impl Send for FontProviderCallbacks {}
unsafe impl Sync for FontProviderCallbacks {}

struct CallbackProvider(FontProviderCallbacks);

/// Enough for any PostScript name a font system will hand back; longer answers are truncated
/// rather than reallocated, because a name that long is a bug on the host's side, not a face.
const NAME_CAP: usize = 256;

fn to_c(s: &str) -> Option<std::ffi::CString> {
    std::ffi::CString::new(s).ok()
}

fn from_buf(buf: &[std::os::raw::c_char]) -> String {
    let bytes: Vec<u8> = buf
        .iter()
        .take_while(|c| **c != 0)
        .map(|c| *c as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

impl FontProvider for CallbackProvider {
    fn face_named(&self, name: &str) -> Option<FaceId> {
        let c = to_c(name)?;
        match (self.0.face_named)(c.as_ptr()) {
            0 => None,
            id => Some(FaceId(id)),
        }
    }

    fn resolve(&self, descriptor: &crate::color_font::NSFontDescriptor) -> Option<FaceId> {
        let flat: Vec<i64> = descriptor
            .featureSettings()
            .iter()
            .flat_map(|(k, v)| [k.rawValue(), *v])
            .collect();
        let base = descriptor.baseFace().map(|f| f.0).unwrap_or(0);
        match (self.0.resolve)(
            base,
            descriptor.symbolicTraits().0,
            flat.as_ptr(),
            flat.len() / 2,
        ) {
            0 => None,
            id => Some(FaceId(id)),
        }
    }

    fn system_face(&self, weight: NSFontWeight, monospaced: bool) -> FaceId {
        FaceId((self.0.system_face)(weight.0, monospaced))
    }

    fn describe(&self, face: FaceId) -> FaceInfo {
        let mut name = [0 as std::os::raw::c_char; NAME_CAP];
        let mut family = [0 as std::os::raw::c_char; NAME_CAP];
        let mut has_family = false;
        let mut traits = 0u32;
        (self.0.describe)(
            face.0,
            name.as_mut_ptr(),
            NAME_CAP,
            family.as_mut_ptr(),
            NAME_CAP,
            &mut has_family,
            &mut traits,
        );
        FaceInfo {
            name: from_buf(&name),
            family: has_family.then(|| from_buf(&family)),
            traits: NSFontDescriptorSymbolicTraits(traits),
        }
    }

    fn covers(&self, face: FaceId, scalar: u32) -> bool {
        (self.0.covers)(face.0, scalar)
    }

    fn substitute(&self, declared: FaceId, scalar: u32) -> Option<FaceId> {
        match (self.0.substitute)(declared.0, scalar) {
            0 => None,
            id => Some(FaceId(id)),
        }
    }
}

/// Installs a host-answered provider. Same one-shot rule as `install`.
pub fn install_callbacks(callbacks: FontProviderCallbacks) -> bool {
    install(Box::new(CallbackProvider(callbacks)))
}
