using System;
using System.Collections.Generic;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using Avalonia.Media.TextFormatting.Unicode;
using Avalonia.Utilities;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// Word-level line breaking for Korean (어절 단위): a paragraph whose style says
/// `eastAsianLineBreak = word` never breaks a line between two Hangul characters while an earlier
/// break opportunity on the same line exists — macOS's `NSParagraphStyle.lineBreakStrategy
/// .hangulWordPriority` (`OfficeTextBuilder.applyLineBreaking`), which the engine's plan is fed on
/// that host. Avalonia's UAX #14 breaker treats every Hangul syllable as a break opportunity and has
/// no such mode, so the reader broke inside Korean words (편람: 720 of 1,257 body line ends).
///
/// Mechanism: the text is NOT rewritten (character indices — selection, hit-testing, footnotes, tabs
/// — stay exactly the block's own). A <see cref="TextFormatter"/> decorator formats each line as
/// Avalonia would; when that line ends between two Hangul characters it picks the last earlier
/// UAX #14 opportunity that is not Hangul–Hangul and formats the line again from a source that ends
/// there, at the same paragraph width (so alignment and justification see the real width). Only
/// layouts built through <see cref="Create"/> with <c>hangulWord: true</c> carry the marker
/// paragraph properties the decorator acts on; every other layout is formatted unchanged. A line
/// with no such earlier opportunity (one word wider than the column) keeps Avalonia's break, as
/// macOS falls inside the word when nothing else fits.
/// </summary>
internal static class HangulWordWrap
{
    private static readonly object InstallLock = new();

    /// <summary>A <see cref="TextLayout"/> with the same meaning as the string constructor's, plus
    /// word-level Hangul breaking when <paramref name="hangulWord"/>.</summary>
    public static TextLayout Create(string text, Typeface typeface, double fontSize, IBrush? foreground,
        TextAlignment alignment, TextWrapping wrapping, double maxWidth, double lineHeight = double.NaN,
        double letterSpacing = 0, IReadOnlyList<ValueSpan<TextRunProperties>>? overrides = null, bool hangulWord = false,
        double firstLineExtra = 0)
    {
        if ((!hangulWord && firstLineExtra == 0) || wrapping == TextWrapping.NoWrap)
        {
            return new TextLayout(text, typeface, fontSize, foreground, alignment, wrapping,
                maxWidth: maxWidth, lineHeight: lineHeight, letterSpacing: letterSpacing, textStyleOverrides: overrides);
        }
        EnsureInstalled();
        var defaults = new GenericTextRunProperties(typeface, fontSize, foregroundBrush: foreground);
        var paragraph = new WordParagraphProperties(text, new GenericTextParagraphProperties(FlowDirection.LeftToRight,
            alignment, true, false, defaults, wrapping, lineHeight, 0, letterSpacing), hangulWord, firstLineExtra);
        return new TextLayout(new SpanTextSource(text, defaults, overrides), paragraph, maxWidth: maxWidth);
    }

    /// <summary>True for a Hangul syllable or jamo (the characters `.hangulWordPriority` keeps together).</summary>
    internal static bool IsHangul(char c) =>
        c is >= '가' and <= '힣' or >= 'ᄀ' and <= 'ᇿ' or >= '㄰' and <= '㆏'
            or >= 'ꥠ' and <= '꥿' or >= 'ힰ' and <= '퟿';

    /// <summary>The line end to use instead of <paramref name="end"/> for a line starting at
    /// <paramref name="start"/>, or <paramref name="end"/> itself when it is not between two Hangul
    /// characters or the line holds no earlier opportunity that is.</summary>
    internal static int WordBreak(string text, int start, int end)
    {
        if (end <= start || end >= text.Length || !IsHangul(text[end - 1]) || !IsHangul(text[end])) { return end; }
        var best = end;
        var breaks = new LineBreakEnumerator(text.AsSpan(start, end - start));
        while (breaks.MoveNext(out var opportunity))
        {
            var p = start + opportunity.PositionWrap;
            if (p <= start || p >= end) { continue; }
            if (IsHangul(text[p - 1]) && IsHangul(text[p])) { continue; }
            best = p;
        }
        return best;
    }

    private static void EnsureInstalled()
    {
        if (TextFormatter.Current is WordFormatter) { return; }
        lock (InstallLock)
        {
            var current = TextFormatter.Current;
            if (current is WordFormatter) { return; }
            // `TextLayout` formats through `TextFormatter.Current`, which reads this binding. The
            // mutable locator is public at run time but absent from Avalonia's reference assembly,
            // hence reflection: `AvaloniaLocator.CurrentMutable.Bind<TextFormatter>().ToConstant(..)`.
            var locator = typeof(AvaloniaLocator).GetProperty("CurrentMutable")!.GetValue(null)!;
            var helper = locator.GetType().GetMethod("Bind", Type.EmptyTypes)!.MakeGenericMethod(typeof(TextFormatter)).Invoke(locator, null)!;
            helper.GetType().GetMethod("ToConstant")!.MakeGenericMethod(typeof(TextFormatter)).Invoke(helper, new object[] { new WordFormatter(current) });
        }
    }

    private sealed class WordFormatter(TextFormatter inner) : TextFormatter
    {
        public override TextLine? FormatLine(ITextSource textSource, int firstTextSourceIndex, double paragraphWidth,
            TextParagraphProperties paragraphProperties, TextLineBreak? previousLineBreak = null)
            => FormatLine(textSource, firstTextSourceIndex, paragraphWidth, paragraphProperties, previousLineBreak, null);

        public override TextLine? FormatLine(ITextSource textSource, int firstTextSourceIndex, double paragraphWidth,
            TextParagraphProperties paragraphProperties, TextLineBreak? previousLineBreak, TextRunCache? textRunCache)
        {
            if (paragraphProperties is not WordParagraphProperties word)
            {
                return inner.FormatLine(textSource, firstTextSourceIndex, paragraphWidth, paragraphProperties, previousLineBreak, textRunCache);
            }
            // The first line of a hanging (or first-line-indented) paragraph wraps at its own width:
            // macOS's `firstLineHeadIndent` against `headIndent`.
            if (firstTextSourceIndex == 0) { paragraphWidth = Math.Max(1, paragraphWidth + word.FirstLineExtra); }
            var line = inner.FormatLine(textSource, firstTextSourceIndex, paragraphWidth, paragraphProperties, previousLineBreak, textRunCache);
            if (line is null || !word.HangulWord) { return line; }
            var end = firstTextSourceIndex + line.Length;
            var chosen = WordBreak(word.Text, firstTextSourceIndex, end);
            if (chosen == end) { return line; }
            line.Dispose();
            // Ending the source at the chosen break makes this line end exactly there, with no
            // TextLineBreak: the layout keeps going from `chosen`, still justifies the line, and the
            // paragraph width (alignment) is the real one.
            return inner.FormatLine(new EndAt(textSource, chosen), firstTextSourceIndex, paragraphWidth, paragraphProperties, null, null);
        }
    }

    private sealed class EndAt(ITextSource source, int end) : ITextSource
    {
        public TextRun? GetTextRun(int textSourceIndex)
        {
            if (textSourceIndex >= end) { return null; }
            var run = source.GetTextRun(textSourceIndex);
            if (run is TextCharacters characters && textSourceIndex + characters.Length > end)
            {
                return new TextCharacters(characters.Text[..(end - textSourceIndex)], characters.Properties!);
            }
            return run;
        }
    }

    /// <summary>The string constructor's source: the text in the override spans' properties, the
    /// defaults where no span covers it, and nothing past the end.</summary>
    private sealed class SpanTextSource(string text, TextRunProperties defaults, IReadOnlyList<ValueSpan<TextRunProperties>>? spans) : ITextSource
    {
        public TextRun? GetTextRun(int textSourceIndex)
        {
            if (textSourceIndex >= text.Length) { return null; }
            var properties = defaults;
            var length = text.Length - textSourceIndex;
            if (spans is not null)
            {
                foreach (var span in spans)
                {
                    var spanEnd = span.Start + span.Length;
                    if (spanEnd <= textSourceIndex) { continue; }
                    if (span.Start > textSourceIndex) { length = span.Start - textSourceIndex; break; }
                    properties = span.Value;
                    length = spanEnd - textSourceIndex;
                    break;
                }
            }
            return new TextCharacters(text.AsMemory(textSourceIndex, Math.Max(1, CoerceToGrapheme(textSourceIndex, length))), properties);
        }

        private int CoerceToGrapheme(int start, int length)
        {
            var total = 0;
            var graphemes = new GraphemeEnumerator(text.AsSpan(start));
            while (graphemes.MoveNext(out var grapheme))
            {
                total += grapheme.Length;
                if (total >= length) { return total; }
            }
            return Math.Min(length, text.Length - start);
        }
    }

    private sealed class WordParagraphProperties(string text, TextParagraphProperties inner, bool hangulWord, double firstLineExtra)
        : TextParagraphProperties
    {
        public string Text { get; } = text;
        /// <summary>Word-level Hangul breaking applies (the paragraph says `eastAsianLineBreak = word`).</summary>
        public bool HangulWord { get; } = hangulWord;
        /// <summary>How much wider than the paragraph width the first line wraps (negative: narrower).</summary>
        public double FirstLineExtra { get; } = firstLineExtra;
        public override FlowDirection FlowDirection => inner.FlowDirection;
        public override TextAlignment TextAlignment => inner.TextAlignment;
        public override double LineHeight => inner.LineHeight;
        public override bool FirstLineInParagraph => inner.FirstLineInParagraph;
        public override bool AlwaysCollapsible => inner.AlwaysCollapsible;
        public override TextRunProperties DefaultTextRunProperties => inner.DefaultTextRunProperties;
        public override TextDecorationCollection? TextDecorations => inner.TextDecorations;
        public override TextWrapping TextWrapping => inner.TextWrapping;
        public override double Indent => inner.Indent;
        public override double ParagraphIndent => inner.ParagraphIndent;
        public override double DefaultIncrementalTab => inner.DefaultIncrementalTab;
        public override double LetterSpacing => inner.LetterSpacing;
    }
}
