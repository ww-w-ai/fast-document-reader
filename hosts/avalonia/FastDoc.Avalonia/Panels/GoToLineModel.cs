namespace FastDoc.Avalonia.Panels;

/// <summary>
/// S9-B3 batch 3 (docs/studio/sprints/S9/s9b1-full-parity.md #24, mirroring
/// DocumentWindowController.swift's Go to Line dialog on macOS): the pure input-validation the
/// "Go to Line…" dialog runs BEFORE it ever touches a <c>FastDoc.Avalonia.Rendering.FlowDocumentView</c>
/// — pulled out so a headless test can drive every case without constructing a real Window.
/// </summary>
public static class GoToLineModel
{
    /// <summary>Parses <paramref name="text"/> as a 1-based line number and validates it against
    /// <paramref name="maxLine"/> (from <c>FlowDocumentView.LineNumberCount</c>). Returns the parsed
    /// number and a null error on success; returns 0 and a reader-facing error message otherwise —
    /// never throws, since every input here comes from a TextBox the reader can type anything into.</summary>
    public static (int LineNumber, string? Error) Validate(string? text, int maxLine)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return (0, "Enter a line number.");
        }
        if (!int.TryParse(text.Trim(), out var value))
        {
            return (0, "Not a number.");
        }
        if (maxLine <= 0)
        {
            return (0, "This document has no lines to go to.");
        }
        if (value < 1 || value > maxLine)
        {
            return (0, $"Enter a number between 1 and {maxLine}.");
        }
        return (value, null);
    }
}
