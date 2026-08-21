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
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NSColor {
    pub red: CGFloat,
    pub green: CGFloat,
    pub blue: CGFloat,
    pub alpha: CGFloat,
}

impl NSColor {
    pub fn srgb(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> Self {
        Self {
            red,
            green,
            blue,
            alpha,
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

    pub fn named(_name: &str, _size: CGFloat) -> Option<Self> {
        todo!("swift: NSFont(name:size:) — phase B (needs CoreText)")
    }
    pub fn with_descriptor(_descriptor: &NSFontDescriptor, _size: CGFloat) -> Option<Self> {
        todo!("swift: NSFont(descriptor:size:) — phase B (needs CoreText)")
    }

    /// swift: NSFont.systemFont(ofSize:) — the one-argument overload, kept as the bare name per
    /// this crate's own precedent (`setWidth`/`setBorderColor` also keep the bare name for their
    /// least-labelled overload; the more specific sibling gets the disambiguating suffix below).
    pub fn systemFont(_size: CGFloat) -> Self {
        todo!("swift: NSFont.systemFont(ofSize:) — phase B")
    }

    /// swift: NSFont.systemFont(ofSize:weight:) — convention §3's overload rule
    /// (`fn name_with_<라벨>`): `ofSize` is already implied by the base name `systemFont`, so
    /// the distinguishing label is `weight` alone, exactly as `setWidthForEdge`'s suffix names
    /// only the label that isn't already on `setWidth`. Named by team-lead request
    /// (render_theme.rs:172), 2026-08-21 — record kept here per convention §3's overload rule.
    pub fn systemFontWeight(_size: CGFloat, _weight: NSFontWeight) -> Self {
        todo!("swift: NSFont.systemFont(ofSize:weight:) — phase B")
    }

    pub fn monospacedSystemFont(_size: CGFloat, _weight: NSFontWeight) -> Self {
        todo!("swift: NSFont.monospacedSystemFont(ofSize:weight:) — phase B")
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
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NSFontDescriptor {
    symbolicTraits: NSFontDescriptorSymbolicTraits,
}

impl NSFontDescriptor {
    /// swift: .symbolicTraits — a method rather than a public field (see `NSFont`'s own fields
    /// above for why); `withSymbolicTraits` below is the copy-and-replace Apple actually exposes,
    /// this crate has no in-scope caller left that needs to mutate one in place.
    pub fn symbolicTraits(&self) -> NSFontDescriptorSymbolicTraits {
        self.symbolicTraits
    }

    pub fn addingAttributes(&self, _attributes: Vec<(NSFontFeatureKey, i64)>) -> Self {
        todo!("swift: NSFontDescriptor.addingAttributes(_:) — phase B")
    }
    pub fn withSymbolicTraits(&self, traits: NSFontDescriptorSymbolicTraits) -> Self {
        Self {
            symbolicTraits: traits,
        }
    }

    /// swift: .postscriptName — needs the real installed font's metadata (CoreText), which this
    /// shim has no backend for yet; matches the `size_with_attributes`/`draw_string_at` precedent
    /// in `drawing_misc.rs` for "font metrics — see CROSS-PLATFORM.md §6".
    pub fn postscriptName(&self) -> Option<String> {
        todo!("swift: NSFontDescriptor.postscriptName — phase B (needs CoreText, see CROSS-PLATFORM.md §6)")
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

/// swift: NSImage — call sites construct with `NSImage(data:)` and `NSImage(size:)` /
/// `NSImage(size:flipped:drawingHandler:)`, and read `.size`.
#[derive(Debug, Clone, PartialEq)]
pub struct NSImage {
    pub size: crate::geometry::CGSize,
}

impl NSImage {
    pub fn fromData(_data: &Data) -> Option<Self> {
        todo!("swift: NSImage(data:) — phase B (needs ImageIO)")
    }
    pub fn withSize(size: crate::geometry::CGSize) -> Self {
        Self { size }
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
