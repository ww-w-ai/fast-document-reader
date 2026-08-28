//! swift: Sources/FastDocReader/Render/RenderTheme.swift and every reader/builder that names
//! `NSColor`/`NSFont`/`NSFontDescriptor`/`NSImage`/`NSBitmapImageRep`/`NSGradient`.
//!
//! `NSColor` is real (a plain RGBA value plus the constructors call sites use) because the
//! reader's own `NSColor(rgb:alpha:)` extension (RenderTheme.swift:5) composes it out of exactly
//! those fields — deferring it would break the very file it lives next to. Everything past
//! colour is `todo!()`: fonts and images need CoreText/ImageIO, a real backend, in phase B.

use crate::foundation::Data;
use crate::geometry::CGFloat;

/// swift: NSColor — call sites read `.redComponent`/`.greenComponent`/`.blueComponent`/
/// `.alphaComponent`, and construct with `NSColor(srgbRed:green:blue:alpha:)`,
/// `NSColor(name:dynamicProvider:)` (the `.dynamic(light:dark:)` helper), and the system color
/// statics (`.systemRed`, `.secondaryLabelColor`, …).
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct NSColor {
    pub red: CGFloat,
    pub green: CGFloat,
    pub blue: CGFloat,
    pub alpha: CGFloat,
    /// Which space those three numbers are IN.
    ///
    /// Not a detail. `NSColor(deviceRed:)` and `NSColor(srgbRed:)` given identical components are
    /// different colours on screen, and the readers do not agree: `OdtReader` builds device RGB
    /// while `DocxReader` and `HwpReader` build sRGB. Carrying only the components — which this
    /// shim did until a host first compared two documents — silently moves every ODT colour.
    pub space: NSColorSpaceName,
}

/// swift: the colour space a call site names by choosing its `NSColor` initialiser.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NSColorSpaceName {
    SRGB,
    DeviceRGB,
}

impl NSColor {
    /// swift: `NSColor(deviceRed:green:blue:alpha:)`
    pub fn device_rgb(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> Self {
        NSColor { red, green, blue, alpha, space: NSColorSpaceName::DeviceRGB }
    }

    /// swift: `NSColor(srgbRed:green:blue:alpha:)`
    pub fn srgb(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> Self {
        Self {
            red,
            green,
            blue,
            alpha,
            space: NSColorSpaceName::SRGB,
        }
    }

    /// swift: NSColor(name: nil) { ap in ap.bestMatch(...) == .darkAqua ? dark : light }
    ///
    /// AppKit resolves this against the live `NSAppearance` at draw time; this shim has no
    /// notion of appearance, so it takes both variants and defers the choice.
    pub fn dynamic(light: NSColor, dark: NSColor) -> DynamicColor {
        DynamicColor { light, dark }
    }

    pub fn redComponent(&self) -> CGFloat {
        self.red
    }
    pub fn greenComponent(&self) -> CGFloat {
        self.green
    }
    pub fn blueComponent(&self) -> CGFloat {
        self.blue
    }
    pub fn alphaComponent(&self) -> CGFloat {
        self.alpha
    }

    /// swift: .usingColorSpace(.deviceRGB) — a color-space conversion; identity until phase B
    /// wires a real color-management backend.
    pub fn usingColorSpaceDeviceRGB(&self) -> Option<NSColor> {
        Some(*self)
    }

    pub fn cgColor(&self) -> NSColor {
        *self
    }

    /// swift: NSColor.clear — a literal color constant (not one of the appearance-dependent
    /// `system_colors`), used as the fallback when a border/background is unset
    /// (GridTextTableBlock.swift: `borderColor(for: edge) ?? .clear`).
    pub fn clear() -> NSColor {
        NSColor::srgb(0.0, 0.0, 0.0, 0.0)
    }

    /// swift: NSColor.black — a literal color constant, alongside `.clear` above.
    pub fn black() -> NSColor {
        NSColor::srgb(0.0, 0.0, 0.0, 1.0)
    }

    /// swift: the reader's own `NSColor(rgb:alpha:)` extension (RenderTheme.swift:5) — packs a
    /// 24-bit hex triplet (`0xRRGGBB`) the way every literal in `RenderTheme.swift`'s palette is
    /// written, rather than three separate 0-1 components like `srgb` above.
    pub fn rgb(hex: u32, alpha: CGFloat) -> NSColor {
        let r = ((hex >> 16) & 0xFF) as CGFloat / 255.0;
        let g = ((hex >> 8) & 0xFF) as CGFloat / 255.0;
        let b = (hex & 0xFF) as CGFloat / 255.0;
        NSColor::srgb(r, g, b, alpha)
    }

    /// swift: .getHue(_:saturation:_:brightness:_:alpha:_:) — reads this color back as HSBA.
    /// Real conversion math (not deferred): it is pure arithmetic over the four components already
    /// stored, the same reasoning `redComponent`/`usingColorSpaceDeviceRGB` above rest on.
    pub fn get_hsba(&self) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let (r, g, b, a) = (self.red, self.green, self.blue, self.alpha);
        let max = r.max(g).max(b);
        let min = r.min(g).min(b);
        let delta = max - min;
        let brightness = max;
        let saturation = if max == 0.0 { 0.0 } else { delta / max };
        let hue = if delta == 0.0 {
            0.0
        } else if max == r {
            60.0 * (((g - b) / delta).rem_euclid(6.0))
        } else if max == g {
            60.0 * ((b - r) / delta + 2.0)
        } else {
            60.0 * ((r - g) / delta + 4.0)
        } / 360.0;
        (hue, saturation, brightness, a)
    }

    /// swift: .setFill() — makes this color the active fill color in the current graphics
    /// context. Needs a live context, so `todo!()`; kept as a real method (not folded into
    /// `NSBezierPath`/`CGRect`'s own drawing calls) because the reader always calls it as its
    /// own statement, one color-then-shape pair at a time.
    pub fn setFill(&self) {
        todo!("swift: NSColor.setFill() — phase B (needs a live graphics context)")
    }

    /// swift: .setStroke()
    pub fn setStroke(&self) {
        todo!("swift: NSColor.setStroke() — phase B (needs a live graphics context)")
    }
}

/// swift: the `NSColor.dynamic(light:dark:)` helper's return value — RenderTheme.swift's
/// `Palette` holds these, not raw `NSColor`, since the light/dark choice is made when drawing.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DynamicColor {
    pub light: NSColor,
    pub dark: NSColor,
}

impl DynamicColor {
    /// swift: resolves `NSColor.dynamic(light:dark:)` against the live `NSAppearance` at draw
    /// time in real AppKit. THE ONE resolver for that resolution in this whole crate — every
    /// appearance-dependent colour (`RenderTheme`'s ~15-entry `Palette`, and the six
    /// `system_colors` below) goes through this single function, not a second copy of the same
    /// "pick one for now" decision re-derived per call site.
    ///
    /// **PHASE A STAND-IN.** This shim has no notion of a live appearance — no host has passed
    /// one in yet — so this always resolves to `light`, unconditionally, today. That is a known,
    /// accepted gap (not a belief that light is correct), and it living in exactly one place is
    /// the point: the day a host-side appearance signal exists, this is the one function that
    /// changes, and every caller — theme colours and system colours alike — picks it up at once.
    /// Before this was hoisted here, `RenderTheme.swift`'s Rust port (`render_theme.rs`) carried
    /// its own file-local copy of this exact same stand-in; that copy should be deleted in favour
    /// of calling this (team-lead routing to that file's owner, not edited here).
    pub fn resolve(&self) -> NSColor {
        self.light
    }
}

/// swift: the NSColor system-color statics the theme and readers reference directly.
///
/// **Provenance (all six, read together):** Apple does not publish guaranteed hex/RGB values for
/// named system colours — they come from a dynamic provider and are documented as able to shift
/// with OS version and accessibility settings (e.g. Increase Contrast). These are MEASURED, not
/// Apple-documented: live `NSColor` introspection on macOS 12.0.1 (Monterey) —
/// <https://gist.github.com/andrejilderda/8677c565cddc969e6aae7df48622d47c> — cross-checked
/// against a second, independently-compiled reference
/// (<https://swiftuicolors.com/macos-colors>, <https://blog.verslu.is/xamarin/ios-macos-dark-mode-dynamic-colors-overview/>)
/// which agrees on five of the six. Treat as "good enough for phase A, known to be a future
/// maintenance point if Apple shifts them in a later macOS release" — the same footing
/// `RenderTheme.swift`'s own hardcoded literals are already on.
pub mod system_colors {
    use super::NSColor;

    /// swift: `NSColor.secondaryLabelColor` — NOT a flat RGB. AppKit implements every label
    /// colour as a translucent overlay (black in light appearance, white in dark), so the alpha
    /// component is load-bearing, not a stylistic extra — dropping it to 1.0 still LOOKS
    /// plausible (a very dark or very light grey), which is exactly what makes it easy to get
    /// quietly wrong.
    pub fn secondaryLabelColor() -> NSColor {
        NSColor::dynamic(
            NSColor::srgb(0.0, 0.0, 0.0, 0.498), // light: black @ 49.8% alpha
            NSColor::srgb(1.0, 1.0, 1.0, 0.549), // dark: white @ 54.9% alpha
        )
        .resolve()
    }

    pub fn systemRed() -> NSColor {
        NSColor::dynamic(
            NSColor::rgb(0xFF3B30, 1.0), // light
            NSColor::rgb(0xFF453A, 1.0), // dark
        )
        .resolve()
    }

    pub fn systemOrange() -> NSColor {
        NSColor::dynamic(
            NSColor::rgb(0xFF9500, 1.0), // light
            NSColor::rgb(0xFF9F0A, 1.0), // dark
        )
        .resolve()
    }

    pub fn systemGreen() -> NSColor {
        NSColor::dynamic(
            NSColor::rgb(0x28CD41, 1.0), // light
            NSColor::rgb(0x32D74B, 1.0), // dark
        )
        .resolve()
    }

    /// swift: `NSColor.systemTeal` — macOS (AppKit) value, deliberately NOT the iOS `UIColor`
    /// value. The two platforms' `systemTeal` genuinely diverge (confirmed against the primary
    /// macOS-specific source above, which disagrees with the community reference's iOS-flavoured
    /// number) — this is a real platform difference, not a sourcing error, so do not "fix" this
    /// to match a `UIColor.systemTeal` table found elsewhere.
    pub fn systemTeal() -> NSColor {
        NSColor::dynamic(
            NSColor::rgb(0x59ADC4, 1.0), // light
            NSColor::rgb(0x6AC4DC, 1.0), // dark
        )
        .resolve()
    }

    pub fn systemPink() -> NSColor {
        NSColor::dynamic(
            NSColor::rgb(0xFF2D55, 1.0), // light
            NSColor::rgb(0xFF375F, 1.0), // dark
        )
        .resolve()
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use super::super::CGFloat;

        // Phase-A stand-in resolves to light — see `DynamicColor::resolve`'s doc. These pin
        // the exact measured light-appearance values so a future edit here (or an accidental
        // light/dark swap) shows up as a failing test, not a silent colour drift.
        #[test]
        fn resolves_to_the_light_appearance_values_for_now() {
            let approx = |c: NSColor, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat| {
                assert!((c.red - r).abs() < 1e-9, "red: {} vs {r}", c.red);
                assert!((c.green - g).abs() < 1e-9, "green: {} vs {g}", c.green);
                assert!((c.blue - b).abs() < 1e-9, "blue: {} vs {b}", c.blue);
                assert!((c.alpha - a).abs() < 1e-9, "alpha: {} vs {a}", c.alpha);
            };
            approx(systemRed(), 0xFF as CGFloat / 255.0, 0x3B as CGFloat / 255.0, 0x30 as CGFloat / 255.0, 1.0);
            approx(secondaryLabelColor(), 0.0, 0.0, 0.0, 0.498);
        }
    }
}

/// swift: NSFont — call sites read `.pointSize`/`.fontName`/`.familyName`/`.fontDescriptor` and
/// construct with `NSFont(name:size:)`, `NSFont(descriptor:size:)`, `.systemFont(ofSize:)`,
/// `.systemFont(ofSize:weight:)`, `.monospacedSystemFont(ofSize:weight:)`.
///
/// Fields are private with accessor methods of the same Swift-property names (`pointSize()`,
/// `fontName()`, `fontDescriptor()`) rather than public fields — matching how every other
/// Swift-property read in this crate is mirrored (`NSColor.redComponent()`,
/// `NSFontDescriptor.symbolicTraits()` below), and how the in-scope call sites
/// (FontSubstitutionResolver.swift, OfficeTextBuilder.swift) actually call them: as messages,
/// not field reads.
#[derive(Debug, Clone, PartialEq)]
pub struct NSFont {
    fontName: String,
    familyName: Option<String>,
    pointSize: CGFloat,
    fontDescriptor: NSFontDescriptor,
}

impl NSFont {
    pub fn fontName(&self) -> String {
        self.fontName.clone()
    }
    pub fn familyName(&self) -> Option<String> {
        self.familyName.clone()
    }
    pub fn pointSize(&self) -> CGFloat {
        self.pointSize
    }
    pub fn fontDescriptor(&self) -> NSFontDescriptor {
        self.fontDescriptor.clone()
    }

    /// An `NSFont` for a face the provider issued, at a size.
    ///
    /// The name and family are ASKED FOR rather than assembled: `describe` is the only thing that
    /// knows what a `FaceId` turned out to be, and a face resolved through a substitution cascade
    /// routinely has a different name — and sometimes a different family — from the one requested.
    pub fn fromFace(face: crate::font_provider::FaceId, size: CGFloat) -> Self {
        let info = crate::font_provider::provider().describe(face);
        NSFont {
            fontName: info.name,
            familyName: info.family,
            pointSize: size,
            fontDescriptor: NSFontDescriptor::fromFace(face, info.traits),
        }
    }

    /// Test-only. `NSFont::named`/`with_descriptor` (below) both defer to CoreText (`todo!()`),
    /// so there is no way, outside this module, to build an `NSFont` with a real face name —
    /// which every test of `size_with_attributes`'s font-metric wiring needs one to exercise the
    /// MEASURED path rather than only the no-`.font`-key default. `#[cfg(test)]` keeps this off
    /// the real public surface entirely; it never ships.
    #[cfg(test)]
    pub(crate) fn for_metrics_test(name: &str, size: CGFloat) -> Self {
        NSFont {
            fontName: name.to_string(),
            familyName: None,
            pointSize: size,
            fontDescriptor: NSFontDescriptor::default(),
        }
    }

    /// Test-only twin of `for_metrics_test` that also carries a family name and symbolic traits
    /// — `text_measure.rs`'s tests need a face whose `fontDescriptor().symbolicTraits()` reports
    /// bold/italic without a real `FontProvider` installed, the same reason the plain version
    /// above exists. `#[cfg(test)]` keeps this off the real public surface entirely.
    #[cfg(test)]
    pub(crate) fn for_metrics_test_with_traits(
        name: &str,
        family: &str,
        size: CGFloat,
        traits: NSFontDescriptorSymbolicTraits,
    ) -> Self {
        NSFont {
            fontName: name.to_string(),
            familyName: Some(family.to_string()),
            pointSize: size,
            fontDescriptor: NSFontDescriptor::default().withSymbolicTraits(traits),
        }
    }

    /// swift: `NSFont(name:size:)` — `nil` when this machine has no such font.
    pub fn named(name: &str, size: CGFloat) -> Option<Self> {
        crate::font_provider::provider().face_named(name).map(|face| Self::of_face(face, size))
    }

    /// swift: `NSFont(descriptor:size:)`
    pub fn with_descriptor(descriptor: &NSFontDescriptor, size: CGFloat) -> Option<Self> {
        crate::font_provider::provider().resolve(descriptor).map(|face| Self::of_face(face, size))
    }

    /// The one constructor: a face the provider issued, at a size. Every public constructor above
    /// funnels through here so an `NSFont` can never hold a face identity nobody resolved.
    fn of_face(face: crate::font_provider::FaceId, size: CGFloat) -> Self {
        let info = crate::font_provider::provider().describe(face);
        NSFont {
            fontName: info.name,
            familyName: info.family,
            pointSize: size,
            fontDescriptor: NSFontDescriptor::of_face(face, info.traits),
        }
    }

    /// swift: NSFont.systemFont(ofSize:) — the one-argument overload, kept as the bare name per
    /// this crate's own precedent (`setWidth`/`setBorderColor` also keep the bare name for their
    /// least-labelled overload; the more specific sibling gets the disambiguating suffix below).
    pub fn systemFont(size: CGFloat) -> Self {
        Self::systemFontWeight(size, NSFontWeight::regular)
    }

    /// swift: NSFont.systemFont(ofSize:weight:) — convention §3's overload rule
    /// (`fn name_with_<라벨>`): `ofSize` is already implied by the base name `systemFont`, so
    /// the distinguishing label is `weight` alone, exactly as `setWidthForEdge`'s suffix names
    /// only the label that isn't already on `setWidth`. Named by team-lead request
    /// (render_theme.rs:172), 2026-08-21 — record kept here per convention §3's overload rule.
    pub fn systemFontWeight(size: CGFloat, weight: NSFontWeight) -> Self {
        Self::of_face(crate::font_provider::provider().system_face(weight, false), size)
    }

    pub fn monospacedSystemFont(size: CGFloat, weight: NSFontWeight) -> Self {
        Self::of_face(crate::font_provider::provider().system_face(weight, true), size)
    }
}

/// swift: NSFont.Weight — a struct wrapping `CGFloat` with static members, not an enum (matching
/// real AppKit exactly, which is why `.regular`/`.semibold` are associated consts here rather
/// than enum variants). Values are Apple's own published raw weights.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NSFontWeight(pub CGFloat);

impl NSFontWeight {
    pub const ultraLight: NSFontWeight = NSFontWeight(-0.8);
    pub const thin: NSFontWeight = NSFontWeight(-0.6);
    pub const light: NSFontWeight = NSFontWeight(-0.4);
    pub const regular: NSFontWeight = NSFontWeight(0.0);
    pub const medium: NSFontWeight = NSFontWeight(0.23);
    pub const semibold: NSFontWeight = NSFontWeight(0.3);
    pub const bold: NSFontWeight = NSFontWeight(0.4);
    pub const heavy: NSFontWeight = NSFontWeight(0.56);
    pub const black: NSFontWeight = NSFontWeight(0.62);
}

/// swift: NSFontDescriptor — call sites read `.symbolicTraits` and pass
/// `[.featureIdentifier: ..., .typeIdentifier: ...]`-shaped feature dictionaries
/// (`NSFontDescriptor.FeatureKey`) for small caps.
/// A face plus whatever has been layered on it, NOT a description anyone can recompose.
///
/// `base` is the identity the provider issued for the face this descriptor was taken from, and it
/// is carried rather than a family name for the reason `font_provider.rs` documents at length:
/// AppKit's system-UI cascades hand back descriptors with no public family, and layering traits on
/// one can land on a different face entirely. Dropping `base` — which this shim did until the
/// render path first tried to USE a descriptor — turns "the same face, one size smaller" into "the
/// default face, one size smaller", silently, on every scaled run in a document.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NSFontDescriptor {
    base: Option<crate::font_provider::FaceId>,
    symbolicTraits: NSFontDescriptorSymbolicTraits,
    /// swift: `.featureSettings` — accumulated by `addingAttributes`, used for small caps.
    features: Vec<(NSFontFeatureKey, i64)>,
}

impl NSFontDescriptor {
    /// swift: .symbolicTraits — a method rather than a public field (see `NSFont`'s own fields
    /// above for why); `withSymbolicTraits` below is the copy-and-replace Apple actually exposes,
    /// this crate has no in-scope caller left that needs to mutate one in place.
    pub fn symbolicTraits(&self) -> NSFontDescriptorSymbolicTraits {
        self.symbolicTraits
    }

    /// The face this descriptor was built FROM, if any — `None` for one that carries nothing but
    /// traits. Exposed for the font port alone: a provider needs to know which face a descriptor
    /// is layering onto, and it must not try to reconstruct one from `family + traits` (see
    /// `font_provider`'s header for the measurement that rules that out).
    pub fn baseFace(&self) -> Option<crate::font_provider::FaceId> {
        self.base
    }

    /// A descriptor that names a face the provider issued, carrying the traits that face reports.
    /// Built here rather than by a caller so `base` stays private and can only ever hold an id the
    /// provider actually handed out.
    pub fn fromFace(
        face: crate::font_provider::FaceId,
        traits: NSFontDescriptorSymbolicTraits,
    ) -> Self {
        NSFontDescriptor { base: Some(face), symbolicTraits: traits, features: Vec::new() }
    }

    /// The `.featureSettings` accumulated by `addingAttributes` — small caps is the only in-scope
    /// user. Exposed for the same reason as `baseFace`: the provider resolves the descriptor, so
    /// it has to see all of it.
    pub fn featureSettings(&self) -> &[(NSFontFeatureKey, i64)] {
        &self.features
    }

    /// swift: `NSFontDescriptor.addingAttributes(_:)` — returns a COPY with these added, which is
    /// why the existing features are kept rather than replaced.
    pub fn addingAttributes(&self, attributes: Vec<(NSFontFeatureKey, i64)>) -> Self {
        let mut copy = self.clone();
        copy.features.extend(attributes);
        copy
    }

    /// swift: `NSFontDescriptor.withSymbolicTraits(_:)` — REPLACES the trait set, it does not
    /// merge; every call site does its own `union` first for exactly that reason.
    pub fn withSymbolicTraits(&self, traits: NSFontDescriptorSymbolicTraits) -> Self {
        Self { base: self.base, symbolicTraits: traits, features: self.features.clone() }
    }

    /// The face this descriptor was derived from, for a `FontProvider` to resolve against.
    pub fn base_face(&self) -> Option<crate::font_provider::FaceId> {
        self.base
    }

    /// swift: `.featureSettings`
    pub fn features(&self) -> &[(NSFontFeatureKey, i64)] {
        &self.features
    }

    /// Builds the descriptor a resolved face carries. Only `NSFont` calls this — a descriptor with
    /// a `base` the provider never issued would be a face identity the engine invented.
    pub(crate) fn of_face(face: crate::font_provider::FaceId, traits: NSFontDescriptorSymbolicTraits) -> Self {
        Self { base: Some(face), symbolicTraits: traits, features: Vec::new() }
    }

    /// swift: `.postscriptName` — the resolved face's name, or `None` when this descriptor has not
    /// been resolved to a face (a trait-only descriptor, which Swift also reports nil for).
    pub fn postscriptName(&self) -> Option<String> {
        self.base.map(|face| crate::font_provider::provider().describe(face).name)
    }
}

/// swift: NSFontDescriptor.SymbolicTraits — an OptionSet (`.bold`, `.italic`, …); the reader's
/// `fontAdding(_:to:)` helpers (FontSubstitutionResolver.swift:169, OfficeTextBuilder.swift:746,
/// MarkdownRenderer.swift:357) union it in, so it is kept as bit flags rather than an enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct NSFontDescriptorSymbolicTraits(pub u32);

impl NSFontDescriptorSymbolicTraits {
    pub const bold: NSFontDescriptorSymbolicTraits = NSFontDescriptorSymbolicTraits(1 << 1);
    pub const italic: NSFontDescriptorSymbolicTraits = NSFontDescriptorSymbolicTraits(1 << 0);

    /// swift: `[]` — an empty `OptionSet` literal (`var traits: NSFontDescriptor.SymbolicTraits
    /// = []`, FontSubstitutionResolver.swift:115, OfficeTextBuilder.swift:557).
    pub fn empty() -> Self {
        NSFontDescriptorSymbolicTraits(0)
    }

    pub fn union(self, other: NSFontDescriptorSymbolicTraits) -> NSFontDescriptorSymbolicTraits {
        NSFontDescriptorSymbolicTraits(self.0 | other.0)
    }

    /// swift: .insert(_:) — `OptionSet`'s in-place union (FontSubstitutionResolver.swift:
    /// 116-117: `traits.insert(.bold)`).
    pub fn insert(&mut self, other: NSFontDescriptorSymbolicTraits) {
        self.0 |= other.0;
    }

    /// swift: .isEmpty
    pub fn isEmpty(&self) -> bool {
        self.0 == 0
    }

    pub fn contains(self, other: NSFontDescriptorSymbolicTraits) -> bool {
        (self.0 & other.0) == other.0
    }
}

/// swift: NSFontDescriptor.FeatureKey — used as a dictionary key
/// (`[NSFontDescriptor.FeatureKey: Int]`) building the small-caps feature attributes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NSFontFeatureKey {
    FeatureIdentifier,
    TypeIdentifier,
    SelectorIdentifier,
}

impl NSFontFeatureKey {
    /// A stable number for the crossing to a host. Not Apple's own constant — these are dictionary
    /// KEYS in AppKit, not integers — so both sides agree on this encoding and nothing else.
    pub fn rawValue(self) -> i64 {
        match self {
            NSFontFeatureKey::FeatureIdentifier => 0,
            NSFontFeatureKey::TypeIdentifier => 1,
            NSFontFeatureKey::SelectorIdentifier => 2,
        }
    }
}

/// swift: NSImage — call sites construct with `NSImage(data:)` and `NSImage(size:)` /
/// `NSImage(size:flipped:drawingHandler:)`, and read `.size`.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct NSImage {
    pub size: crate::geometry::CGSize,
    pub data: Option<Data>,
    /// Where the bytes are, when they are not here.
    ///
    /// A real document uses the same picture in many places — 610 of one government manual's table
    /// cells share 44 background images — and `data` writes a fresh base64 copy at every one of
    /// them. `office_export` therefore moves the bytes into the result's own `images` map before
    /// serializing and leaves this key pointing at them, which is the map the host already resolves
    /// pictures through. In memory `data` stays exactly as it was; this is a property of the WIRE.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data_key: Option<crate::nsstring::SwiftString>,
}

impl NSImage {
    /// The picture's SIZE, without decoding the picture.
    ///
    /// Nothing in this port ever draws from an `NSImage` — the host does that, from `data`. Every
    /// caller here wants two numbers, and `image::load_from_memory` was decoding whole bitmaps to
    /// produce them: measured on one government manual, 214.8 ms of a 950 ms read, 23% of the
    /// engine's entire time for a document (`engine_stage_cost.rs`). Reading the header answers the
    /// same question.
    ///
    /// This is slightly weaker as a validity check than a full decode — a file with a good header
    /// and a corrupt body now passes here and fails later, where the host tries to draw it. That is
    /// the behaviour a picture already has when a document names one it has no bytes for: the box
    /// is reserved and nothing is painted in it (invariant 1). Bytes that are not an image at all
    /// still answer `None`, because a format cannot be guessed for them.
    pub fn fromData(data: &Data) -> Option<Self> {
        let reader = image::ImageReader::new(std::io::Cursor::new(&data.0))
            .with_guessed_format()
            .ok()?;
        let (width, height) = reader.into_dimensions().ok()?;
        Some(Self {
            size: crate::geometry::CGSize {
                width: width as crate::geometry::CGFloat,
                height: height as crate::geometry::CGFloat,
            },
            data: Some(data.clone()),
            data_key: None,
        })
    }
    pub fn withSize(size: crate::geometry::CGSize) -> Self {
        Self { size, data: None, data_key: None }
    }

    /// swift: `NSImage(size:flipped:drawingHandler:)` — the drawing handler is called by AppKit
    /// with a live graphics context and a `CGRect` to draw into, returning whether it drew;
    /// needs that live context, so `todo!()` like every other drawing call in this crate.
    pub fn with_drawing(
        size: crate::geometry::CGSize,
        _flipped: bool,
        _drawing_handler: impl FnMut(crate::geometry::CGRect) -> bool,
    ) -> Self {
        let _ = size;
        todo!("swift: NSImage(size:flipped:drawingHandler:) — phase B (needs a live graphics context)")
    }

    /// swift: `.draw(in:from:operation:fraction:respectFlipped:hints:)` — the 3-argument
    /// convenience shape (`rect`, source point, `.sourceOver` implied by a bare `bool`) the
    /// in-scope table-drawing call sites use in place of the full 6-argument `draw` below.
    pub fn draw_in(&self, _rect: crate::geometry::CGRect, _from: crate::geometry::CGPoint, _source_over: bool) {
        todo!("swift: NSImage.draw(in:from:operation:fraction:respectFlipped:hints:) — phase B")
    }
}

/// swift: NSBitmapImageRep
#[derive(Debug, Clone)]
pub struct NSBitmapImageRep;

impl NSBitmapImageRep {
    pub fn pngRepresentation(&self) -> Option<Data> {
        todo!("swift: NSBitmapImageRep.representation(using: .png, properties:) — phase B")
    }
}

/// swift: NSGradient
#[derive(Debug, Clone)]
pub struct NSGradient {
    pub colors: Vec<NSColor>,
}

impl NSGradient {
    pub fn new(colors: Vec<NSColor>) -> Option<Self> {
        Some(Self { colors })
    }
    pub fn draw(&self, _rect: crate::geometry::CGRect, _angle: CGFloat) {
        todo!("swift: NSGradient.draw(in:angle:) — phase B (drawing, host-resident in practice)")
    }
}

#[cfg(test)]
mod image_size_tests {
    use super::*;

    /// A picture's size is `NSImage::fromData`'s whole contract — nothing in this port draws, so
    /// the two numbers ARE the value. Nothing checked them until reading them stopped requiring a
    /// full decode (a 214.8 ms saving on one real document, `engine_stage_cost.rs`): changing the
    /// width by seven pixels left the entire workspace green.
    #[test]
    fn a_pictures_size_is_the_size_its_header_declares() {
        for (width, height) in [(1u32, 1u32), (3, 5), (64, 17)] {
            let mut encoded = std::io::Cursor::new(Vec::new());
            image::RgbaImage::new(width, height)
                .write_to(&mut encoded, image::ImageFormat::Png)
                .expect("the test can encode a PNG");
            let image = NSImage::fromData(&Data(encoded.into_inner()))
                .expect("a PNG this crate just wrote is readable");
            assert_eq!(image.size.width, width as crate::geometry::CGFloat);
            assert_eq!(image.size.height, height as crate::geometry::CGFloat);
        }
    }

    /// Bytes that are not a picture answer `None` rather than a picture of no size — the caller's
    /// `?` is what keeps a non-image out of the layout, and it only works if this says so.
    #[test]
    fn bytes_that_are_not_a_picture_are_not_a_picture() {
        assert!(NSImage::fromData(&Data(b"this is not an image".to_vec())).is_none());
        assert!(NSImage::fromData(&Data(Vec::new())).is_none());
    }
}
