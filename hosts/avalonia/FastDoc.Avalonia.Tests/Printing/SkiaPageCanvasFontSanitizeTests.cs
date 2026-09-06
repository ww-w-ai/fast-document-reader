using System.Reflection;
using SkiaSharp;
using FastDoc.Avalonia.Printing;

namespace FastDoc.Avalonia.Tests.Printing;

/// <summary>
/// S8-A4: pins <c>SkiaPageCanvas</c>'s private <c>SanitizeForBundledFont</c> against the bundled
/// font's REAL glyph coverage — the two codepoints A3 measured drawing a `.notdef` tofu box on the
/// VM's headless <c>--pdf</c> path while the GUI showed a plain space at the identical spot:
/// U+000A LINE FEED (the docx code-example blocks' whole-run break marker) and U+2007 FIGURE SPACE
/// (the HWP table-of-contents leader — confirmed by dumping the manual's own textRun nodes, see
/// docs/studio/sprints/S8/s8a2-render-fixes.md's A4 section; an earlier guess of U+2024 ONE DOT
/// LEADER read a form-field template line, not an actual TOC entry).
///
/// The method is <c>private static</c> by design (it is an internal drawing detail, not part of
/// <see cref="IPageCanvas"/>'s contract) — reached here via reflection, the same way this repo's
/// own <c>RecursionGuardTests</c> reached a private method before its API was made public. Unlike
/// that case, this one has no reason to become public: nothing outside <c>SkiaPageCanvas</c> ever
/// needs to sanitize a run for a font it does not own.
/// </summary>
public class SkiaPageCanvasFontSanitizeTests
{
    // SkiaPageCanvas.LoadBundledTypeface() reads the bundled font through Avalonia's AssetLoader,
    // which needs the platform initialized once per test run — same headless setup
    // PageModePainterSinglePageExportTests.cs uses for its own SkiaPageCanvas construction.
    public SkiaPageCanvasFontSanitizeTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static readonly MethodInfo SanitizeMethod =
        typeof(SkiaPageCanvas).GetMethod("SanitizeForBundledFont", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new System.MissingMethodException(nameof(SkiaPageCanvas), "SanitizeForBundledFont");

    private static string Sanitize(string text, SKFont font) =>
        (string)SanitizeMethod.Invoke(null, new object[] { text, font })!;

    [Fact]
    public void A_line_feed_control_character_is_replaced_with_a_plain_space()
    {
        using var typeface = SkiaPageCanvas.LoadBundledTypeface();
        using var font = new SKFont(typeface, 12f);

        // "<tag>\n</tag>" is exactly the shape a docx XML/code example block's whole-run break
        // marker takes once FlowDocumentBuilder's control-char splitter turns an embedded '\n'
        // into its own run — the LITERAL LF still reaches this method for that run's text.
        var sanitized = Sanitize("<tag>\n</tag>", font);

        Assert.DoesNotContain('\n', sanitized);
        Assert.Equal("<tag> </tag>", sanitized);
    }

    [Fact]
    public void A_figure_space_toc_leader_is_replaced_with_a_plain_space()
    {
        using var typeface = SkiaPageCanvas.LoadBundledTypeface();
        using var font = new SKFont(typeface, 12f);

        // The exact codepoint sequence dumped from the 편람 hwp's own table-of-contents textRun:
        // title, U+2007 FIGURE SPACE, page number — no dot leader glyph is involved at all.
        var sanitized = Sanitize("제1장 행정업무 운영 개요 1", font);

        Assert.DoesNotContain(' ', sanitized);
        Assert.Equal("제1장 행정업무 운영 개요 1", sanitized);
    }

    [Fact]
    public void Ordinary_hangul_latin_and_digits_are_never_touched()
    {
        using var typeface = SkiaPageCanvas.LoadBundledTypeface();
        using var font = new SKFont(typeface, 12f);

        const string ordinary = "제1장 Chapter One <element attr=\"value\"/> 123";
        Assert.Equal(ordinary, Sanitize(ordinary, font));
    }

    [Fact]
    public void A_bold_monospace_sized_run_gets_the_same_glyph_coverage_substitution()
    {
        // FastDoc.Avalonia's SkiaPageCanvas resolves ONE bundled typeface for every run
        // (GetOrBuildFont varies only weight/style/size, never family — there is no separate
        // per-family font resolution to diverge for a "monospace" declared family). So the
        // glyph-coverage gap this test pins is not specific to one weight/size/style combination;
        // this proves that holds for a bold, larger-than-body size too (the shape a code block's
        // declared font commonly renders at), not only the default weight the two tests above use.
        using var typeface = SkiaPageCanvas.LoadBundledTypeface();
        using var font = new SKFont(typeface, 14f) { Embolden = true };

        var sanitized = Sanitize("<element>\n", font);

        Assert.DoesNotContain('\n', sanitized);
        Assert.Equal("<element> ", sanitized);
    }
}
