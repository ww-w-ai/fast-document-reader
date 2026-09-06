using System;
using System.IO;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// S9-B3 batch 5 (docs/studio/sprints/S9/s9b1-full-parity.md #43, mirroring
/// ReaderTextView.swift:798-800's Cmd-click-on-selection behaviour on macOS): decides what a
/// Ctrl/Cmd-click on a SELECTED range of text should open, as a pure function of the selected
/// string — a well-formed absolute URI, or a path that exists on disk. Pulled out of
/// <see cref="FlowDocumentView"/> so this decision is testable without a live window or a real
/// filesystem probe living inline in the pointer handler.
/// </summary>
public static class SelectionOpenTarget
{
    /// <summary>The string to hand <see cref="IExternalLinkLauncher.Open"/>, or null when the
    /// selected text is neither a URI nor an existing file path — a Ctrl/Cmd-click on ordinary
    /// prose text must be a no-op, not an attempt to "open" a sentence.</summary>
    public static string? Resolve(string? selectedText)
    {
        if (string.IsNullOrWhiteSpace(selectedText)) { return null; }
        var trimmed = selectedText.Trim();

        // http(s)/mailto need no filesystem check — a network/mail scheme is always "openable" as
        // far as this reader can tell without making a request. `Uri.TryCreate` also happily
        // parses any absolute Unix path (leading "/") as an ABSOLUTE Uri with Scheme == "file", so
        // that case is deliberately routed through the SAME existence check as a bare path below
        // rather than trusted just because it parsed — otherwise every non-existent absolute path
        // a reader selects would be reported "openable".
        if (Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)
            && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == "mailto"))
        {
            return trimmed;
        }

        var candidatePath = uri is { Scheme: "file" } ? uri.LocalPath : trimmed;
        try
        {
            if (File.Exists(candidatePath) || Directory.Exists(candidatePath)) { return trimmed; }
        }
        catch
        {
            // A selection containing characters illegal in a path (most prose) throws from
            // File.Exists/Directory.Exists on some platforms rather than returning false —
            // treated the same as "not a path".
        }
        return null;
    }
}
