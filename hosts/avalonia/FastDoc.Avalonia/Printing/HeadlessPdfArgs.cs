using System;
using System.Globalization;

namespace FastDoc.Avalonia.Printing;

/// <summary>Arguments after <c>--pdf</c>, mirroring the macOS <c>HeadlessPDF.parseArgs</c>: one input,
/// an output (second positional or <c>-o</c>; default is the input's own name with <c>.pdf</c>),
/// <c>-f</c> (accepted; this host always overwrites) and <c>-s/--font-size &lt;pt&gt;</c>. A size
/// outside 10-36 is refused, never clamped. The size is the headless run's own: the viewer's stored
/// zoom is never read here.</summary>
public sealed record HeadlessPdfArgs(string Input, string Output, double FontSizePoints)
{
    public const double MinFontSize = 10;
    public const double MaxFontSize = 36;
    /// <summary>The macOS default body size; the Avalonia view's zoom 1.0 corresponds to it.</summary>
    public const double DefaultFontSize = 16;

    public const string Usage =
        "usage: FastDoc --pdf <file> [<out.pdf> | -o <out.pdf>] [-f] [-s <pt>]\n" +
        "  -s, --font-size <pt>   body text size, 10-36 (default: 16); the viewer's own zoom never applies";

    /// <summary>The view zoom factor that gives <see cref="FontSizePoints"/>.</summary>
    public double Zoom => FontSizePoints / DefaultFontSize;

    public static HeadlessPdfArgs? Parse(string[] args)
    {
        string? input = null, output = null;
        var size = DefaultFontSize;
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "-o":
                case "--output":
                    if (++i >= args.Length) { return null; }
                    output = args[i];
                    break;
                case "-f":
                case "--force":
                    break;
                case "-s":
                case "--font-size":
                    if (++i >= args.Length
                        || !double.TryParse(args[i], NumberStyles.Float, CultureInfo.InvariantCulture, out var v)
                        || double.IsNaN(v) || v < MinFontSize || v > MaxFontSize) { return null; }
                    size = v;
                    break;
                default:
                    if (args[i].StartsWith('-')) { return null; }
                    if (input is null) { input = args[i]; }
                    else if (output is null) { output = args[i]; }
                    else { return null; }
                    break;
            }
        }
        if (input is null) { return null; }
        output ??= System.IO.Path.ChangeExtension(input, ".pdf");
        return new HeadlessPdfArgs(input, output, size);
    }
}
