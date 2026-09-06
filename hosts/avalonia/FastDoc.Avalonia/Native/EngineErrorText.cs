using System;
using System.Text.Json;

namespace FastDoc.Avalonia.Native;

/// <summary>
/// The ONE place that turns an engine wire-level error (ffi_guard.rs's <c>FfiErrorKind</c> tag +
/// its message) into a sentence a person can read, so <see cref="Rendering.RenderTreeLoader"/>'s
/// callers (MainWindow's status line, Program.cs's headless doors) never show a Rust
/// <c>Debug</c>-formatted struct or a raw JSON envelope. Every kind the FFI crate defines is
/// mapped explicitly below; an unrecognized kind keeps the original text verbatim with an
/// " (engine error)" suffix, so it is visibly a lower-level diagnostic rather than a fabricated
/// explanation, and the message is never silently dropped (docs/studio/sprints/S6/
/// s6e-error-surface.md, scenarios 1b/8).
/// </summary>
public static class EngineErrorText
{
    /// <summary>Humanizes one <see cref="Model.RenderTreeError"/>'s kind+message pair.
    /// <paramref name="extension"/> is the document's own extension (no leading dot, e.g. "hwpx")
    /// where the caller has one — it names the file kind in the sentence ("This .hwpx file...")
    /// instead of the generic "This file...".</summary>
    public static string Humanize(string? kind, string? message, string? extension = null)
    {
        // fastdoc_office_open's failures are recorded through fastdoc_take_last_error, whose text
        // is itself a JSON envelope ({"kind":...,"message":...,"location":...} —
        // FfiFailure::to_last_error_json in ffi_guard.rs) rather than a flat sentence.
        // RenderTreeLoader.ReadOfficeTree carries that raw JSON string as the OUTER
        // RenderTreeError's Message under the kind "ffiFailure" (see its own doc comment). Unwrap
        // it once so an office-open failure gets the SAME human sentence a tree_json failure of
        // the same underlying kind would get.
        if (string.Equals(kind, "ffiFailure", StringComparison.Ordinal)
            && TryUnwrapEnvelope(message, out var innerKind, out var innerMessage))
        {
            return Humanize(innerKind, innerMessage, extension);
        }

        var fileNoun = string.IsNullOrEmpty(extension) ? "file" : $".{extension.TrimStart('.')} file";

        return kind switch
        {
            // Already a human sentence written by the archive reader itself (ZipArchiveError's
            // own Display impl) — e.g. "Not a ZIP archive: no end-of-central-directory record
            // found." — so this only frames which document it is about (scenario 1a: already OK
            // as-is, this just makes the .hwpx/.docx case read the same way).
            "invalidArchive" => string.IsNullOrWhiteSpace(message)
                ? $"This {fileNoun} is damaged or not a valid archive."
                : $"This {fileNoun} is damaged or not a valid archive ({message}).",

            "hwpReadFailed" => $"This {fileNoun} is damaged or in a format this reader cannot parse.",

            // Already a plain sentence built by RenderTreeLoader.Load itself
            // ("no reader for .xyz") — pass it through.
            "unsupportedExtension" => message ?? $"This {fileNoun} type is not supported.",

            // readerFailed's message is a Rust `{error:?}` Debug dump (fastdoc-ffi/src/lib.rs) —
            // e.g. "InvalidUtf8 { valid_up_to: 0 }" for PlainTextError::InvalidUtf8 (scenario 8).
            // That is the only readerFailed shape known to occur on a real document today; every
            // other one falls through to the generic suffix below rather than guessing.
            "readerFailed" when IsInvalidUtf8Debug(message) =>
                "This file is not valid UTF-8 text.",
            "readerFailed" => Suffix(message, "the document reader failed"),

            "exportFailed" => Suffix(message, "the document could not be converted"),
            "invalidArgument" => Suffix(message, "an internal argument was invalid"),
            "interiorNul" => Suffix(message, "the document text is invalid"),
            "panic" => Suffix(message, "the engine crashed while reading this document"),
            "hostFontProviderMissing" or "hostTextMeasurerMissing" =>
                Suffix(message, "an internal component was not ready"),

            _ => Suffix(message, "the engine reported an error"),
        };
    }

    private static string Suffix(string? message, string fallback) =>
        string.IsNullOrWhiteSpace(message) ? $"{fallback} (engine error)" : $"{message} (engine error)";

    /// <summary>True for the one readerFailed shape this app maps by name:
    /// <c>PlainTextError::InvalidUtf8 { valid_up_to: N }</c>'s Debug text starts with
    /// "InvalidUtf8". Checked by substring rather than a full parse — this is a Rust Debug dump,
    /// not a contract this host owns the shape of.</summary>
    private static bool IsInvalidUtf8Debug(string? message) =>
        message is not null && message.Contains("InvalidUtf8", StringComparison.Ordinal);

    /// <summary>Parses <paramref name="message"/> as the last-error JSON envelope
    /// (<c>{"kind":"...","message":"...","location":...}</c>) and extracts its inner kind and
    /// message. False for anything that is not that shape — a flat sentence is not JSON and must
    /// not be run through this a second time.</summary>
    private static bool TryUnwrapEnvelope(string? message, out string? kind, out string? innerMessage)
    {
        kind = null;
        innerMessage = null;
        if (string.IsNullOrWhiteSpace(message))
        {
            return false;
        }
        try
        {
            using var document = JsonDocument.Parse(message);
            if (document.RootElement.ValueKind != JsonValueKind.Object
                || !document.RootElement.TryGetProperty("kind", out var kindElement)
                || kindElement.ValueKind != JsonValueKind.String)
            {
                return false;
            }
            kind = kindElement.GetString();
            if (document.RootElement.TryGetProperty("message", out var messageElement)
                && messageElement.ValueKind == JsonValueKind.String)
            {
                innerMessage = messageElement.GetString();
            }
            return kind is not null;
        }
        catch (JsonException)
        {
            return false;
        }
    }
}
