using FastDoc.Avalonia.Native;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// EngineErrorText.Humanize (Native/EngineErrorText.cs) — the one place that turns a wire-level
/// engine error (kind + Rust-side message) into a sentence a person can read. Pure unit tests: no
/// FASTDOC_ENGINE_LIB needed, since this class never touches the native library itself.
/// </summary>
public class EngineErrorTextTests
{
    [Fact]
    public void ReaderFailed_InvalidUtf8_debug_dump_becomes_a_plain_sentence()
    {
        // The exact shape fastdoc-ffi/src/lib.rs's `format!("{error:?}")` produces for
        // PlainTextError::InvalidUtf8 (S6-E scenario 8) — must not leak the Rust struct syntax.
        var text = EngineErrorText.Humanize("readerFailed", "InvalidUtf8 { valid_up_to: 0 }");

        Assert.Equal("This file is not valid UTF-8 text.", text);
        Assert.DoesNotContain("valid_up_to", text);
        Assert.DoesNotContain("{", text);
    }

    [Fact]
    public void FfiFailure_envelope_is_unwrapped_to_its_inner_kind()
    {
        // fastdoc_office_open's own last-error text (ffi_guard.rs's FfiFailure::to_last_error_json)
        // is a JSON envelope carried as the OUTER RenderTreeError's message under kind
        // "ffiFailure" (S6-E scenario 1b) — must not be shown to the user as raw JSON.
        var text = EngineErrorText.Humanize(
            "ffiFailure",
            "{\"kind\":\"hwpReadFailed\",\"message\":\"CFB open failed\",\"location\":null}",
            "hwp");

        Assert.Equal("This .hwp file is damaged or in a format this reader cannot parse.", text);
        Assert.DoesNotContain("{", text);
        Assert.DoesNotContain("\"kind\"", text);
    }

    [Fact]
    public void InvalidArchive_names_the_documents_own_extension()
    {
        var text = EngineErrorText.Humanize(
            "invalidArchive",
            "Not a ZIP archive: no end-of-central-directory record found.",
            "docx");

        Assert.StartsWith("This .docx file is damaged or not a valid archive", text);
        Assert.Contains("no end-of-central-directory record found", text);
    }

    [Fact]
    public void Unmapped_kind_keeps_the_original_message_with_an_engine_error_suffix()
    {
        // A kind this app has no explicit mapping for must never be silently dropped — the
        // original text survives, visibly tagged as a lower-level diagnostic.
        var text = EngineErrorText.Humanize("someBrandNewKind", "a totally new failure shape");

        Assert.Equal("a totally new failure shape (engine error)", text);
    }

    [Fact]
    public void Unsupported_extension_message_passes_through_unchanged()
    {
        // RenderTreeLoader.Load already writes a plain sentence for this kind ("no reader for
        // .xyz") — EngineErrorText must not wrap or alter it.
        var text = EngineErrorText.Humanize("unsupportedExtension", "no reader for .xyz");

        Assert.Equal("no reader for .xyz", text);
    }

    [Fact]
    public void Null_kind_and_message_do_not_throw()
    {
        var text = EngineErrorText.Humanize(null, null);

        Assert.False(string.IsNullOrEmpty(text));
    }
}
