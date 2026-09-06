using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Native;

namespace FastDoc.Avalonia.Rendering;

/// <summary>The result of opening one document: the parsed tree (or the engine's own error) plus
/// how long it took, timed the same way for every document kind so callers can compare them.
/// E2d: <see cref="Handle"/> is the still-open office parse behind this tree — null for
/// markdown/text (no handle) and for a failed open. The caller now owns it: dispose it when this
/// document is replaced by another (a new Load/LoadWithBreakdown call) or the process exits, so
/// a picture can be fetched lazily (<see cref="OfficeDocumentHandle.ImageBytes"/>) for as long as
/// the document stays open, never re-reading the file from disk to answer one query.
/// <paramref name="DocumentPath"/> is the file this tree was read from — carried alongside
/// <see cref="Handle"/> so a docx/odt picture with no eager bytes and no live-parse handle
/// (fastdoc_office_image_base64's own "ask elsewhere" contract for those formats) can still be
/// found: their pictures live in the file's own zip archive, opened lazily by
/// <see cref="ImageBlockRenderer"/> from this path, never from the handle.</summary>
public sealed record LoadResult(RenderTree? Tree, RenderTreeError? Error, long ElapsedMs, OfficeDocumentHandle? Handle = null, string? DocumentPath = null)
{
    public bool IsOk => Tree is not null;
}

/// <summary>The same open, but with the FFI call (native parse + JSON marshal) and the JSON
/// deserialize (native string -> RenderTree records) timed separately, for D4's breakdown of
/// where LoadResult.ElapsedMs actually goes. <see cref="Handle"/> carries the same lifetime
/// contract as LoadResult.Handle.</summary>
public sealed record LoadBreakdown(RenderTree? Tree, RenderTreeError? Error, long FfiMs, long DeserializeMs, OfficeDocumentHandle? Handle = null, string? DocumentPath = null)
{
    public bool IsOk => Tree is not null;
}

/// <summary>E2d: an office document handle kept alive past the initial tree read, so a picture's
/// bytes can be fetched from the SAME parse on demand (P2c's docx/odt shape, extended to every
/// office format that keeps a live parse) instead of every picture being decoded whether or not it
/// is ever drawn. One owner, one close: whoever receives this from RenderTreeLoader must call
/// Dispose exactly once — never twice, never after a reload has already replaced it (the same rule
/// fastdoc_engine_ffi.h states for fastdoc_office_close itself).</summary>
public sealed class OfficeDocumentHandle : IDisposable
{
    private IntPtr _handle;

    internal OfficeDocumentHandle(IntPtr handle)
    {
        _handle = handle;
    }

    /// <summary>E2c-1: the raw native handle, for the S5C1-02/S5C2-01 page-geometry queries
    /// (<see cref="Paging.PageBandResolver"/>/<see cref="Paging.PageSheetsResolver"/>) that need to
    /// pass it straight to `fastdoc_office_band_sides`/`fastdoc_office_sheets` — those calls are
    /// pure/NULL-checked on the native side (fastdoc_engine_ffi.h's own doc: "handle is unused
    /// beyond the NULL check" for sheets), so exposing it read-only here adds no new ownership
    /// rule beyond the one this class already states: never call after Dispose.</summary>
    public IntPtr RawHandle => _handle;

    /// <summary>One embedded picture's bytes, decoded from the base64 the engine returns, fetched
    /// from the parse this handle still holds. <paramref name="resourceKey"/> is the document's
    /// OWN id for the resource (RenderTree wire's Resource.sourceKey, e.g. "hwpimg:3") — NOT the
    /// tree's numeric resource id, which the engine does not accept here. Returns null for a key
    /// this document does not have, a document with no live parse to ask (docx/odt — their
    /// pictures come from the archive, not this handle), malformed base64, or a handle already
    /// disposed. Never throws over one bad picture.</summary>
    public byte[]? ImageBytes(string resourceKey)
    {
        if (_handle == IntPtr.Zero || string.IsNullOrEmpty(resourceKey)) { return null; }
        var keyBytes = FastdocEngine.Utf8NulTerminated(resourceKey);
        var ptr = FastdocEngine.fastdoc_office_image_base64(_handle, keyBytes);
        var base64 = FastdocEngine.TakeOwnedString(ptr);
        if (base64 is null) { return null; }
        try { return Convert.FromBase64String(base64); }
        catch { return null; }
    }

    public void Dispose()
    {
        if (_handle == IntPtr.Zero) { return; }
        FastdocEngine.fastdoc_office_close(_handle);
        _handle = IntPtr.Zero;
    }
}

/// <summary>
/// Opens a document through the right FFI door for its extension: markdown/plain text goes
/// through fastdoc_read_text_tree (an already fully-formed structural tree, one call); every
/// office extension (docx/docm/dotx/dotm/odt/hwp/hwpx) goes through the
/// open -> tree_json -> close triple, because that family's tree is a SECOND projection over a
/// parse the engine keeps alive in the handle, not a one-shot read. Office documents' tree is
/// STRUCTURE ONLY at this schema version — the engine has not placed it on a page yet, unlike
/// the markdown path, which the reader already lays out front-first (see the README).
/// </summary>
public static class RenderTreeLoader
{
    /// <summary>Runs <paramref name="body"/>, disposing <paramref name="resource"/> exactly once
    /// if it throws. <see cref="Load"/> and
    /// <see cref="LoadWithBreakdown"/> both wrap their JSON-deserialize step in this so an already
    /// <c>fastdoc_office_open</c>'d <see cref="OfficeDocumentHandle"/> is never leaked past a
    /// malformed/truncated envelope or a decoded "ok" payload that does not match
    /// <see cref="RenderTree"/> — factored out to a plain <see cref="IDisposable"/> so the
    /// disposal GUARANTEE is unit-testable with a spy object, without needing a real native handle
    /// or a way to make the engine itself return malformed JSON (see
    /// RenderTreeLoaderHandleDisposalTests in the test project).</summary>
    public static TResult RunDisposingOnThrow<TResult>(IDisposable? resource, Func<TResult> body)
    {
        try
        {
            return body();
        }
        catch
        {
            resource?.Dispose();
            throw;
        }
    }

    private static readonly HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "md", "markdown", "txt", "text", "csv", "tsv", "log", "json", "yaml", "yml", "toml",
        "ini", "conf", "cfg", "sh", "bash", "zsh", "py", "rb", "js", "ts", "swift", "rs", "go",
        "c", "h", "cpp", "hpp", "java", "kt", "sql", "xml", "html", "css",
    };

    private static readonly HashSet<string> OfficeExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "docx", "docm", "dotx", "dotm", "odt", "hwp", "hwpx",
    };

    /// <summary>S7-G: lets `--extract` (Program.cs) tell an office document (whose tree needs
    /// `MarkdownSerializer`) apart from a text one (already Markdown/plain text — printed
    /// verbatim, the same choice `HeadlessExtract.swift` makes for `.markdown`/`.plainText`)
    /// without duplicating this file's own extension list.</summary>
    public static bool IsOfficeExtension(string extension) => OfficeExtensions.Contains(extension);

    public static LoadResult Load(string path)
    {
        var extension = Path.GetExtension(path).TrimStart('.');
        var bytes = File.ReadAllBytes(path);

        var stopwatch = Stopwatch.StartNew();
        string? json;
        OfficeDocumentHandle? handle = null;
        if (TextExtensions.Contains(extension))
        {
            json = ReadTextTree(bytes, extension);
        }
        else if (OfficeExtensions.Contains(extension))
        {
            (json, handle) = ReadOfficeTree(bytes, extension);
        }
        else
        {
            stopwatch.Stop();
            return new LoadResult(null,
                new RenderTreeError { Kind = "unsupportedExtension", Message = $"no reader for .{extension}" },
                stopwatch.ElapsedMilliseconds);
        }

        if (json is null)
        {
            stopwatch.Stop();
            handle?.Dispose(); // open succeeded but tree_json failed -- nothing else will query it
            var lastError = FastdocEngine.TakeLastError();
            return new LoadResult(null,
                new RenderTreeError { Kind = "ffiFailure", Message = lastError ?? "no envelope returned" },
                stopwatch.ElapsedMilliseconds);
        }

        // Deserialization below can throw (malformed/truncated JSON from the engine, or a decoded
        // envelope whose "ok" payload does not match RenderTree) — an already
        // fastdoc_office_open'd handle must not leak past that throw. RunDisposingOnThrow disposes
        // it on every exception path; the envelope.Error branch below is a normal (non-exception)
        // return, so it disposes explicitly and clears `handle` first, same as the success path,
        // so a live handle is never closed twice.
        var (tree, envelopeError) = RunDisposingOnThrow(handle, () =>
        {
            var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)
                ?? throw new InvalidOperationException("empty envelope JSON");
            stopwatch.Stop();
            if (envelope.Error is not null) { return (Tree: (RenderTree?)null, Error: envelope.Error); }
            var decoded = envelope.Ok!.Value.Deserialize<RenderTree>()
                ?? throw new InvalidOperationException("envelope.ok did not decode to a RenderTree");
            return (Tree: (RenderTree?)decoded, Error: (RenderTreeError?)null);
        });

        if (envelopeError is not null)
        {
            handle?.Dispose();
            return new LoadResult(null, envelopeError, stopwatch.ElapsedMilliseconds);
        }
        var successHandle = handle;
        handle = null;
        return new LoadResult(tree, null, stopwatch.ElapsedMilliseconds, successHandle, path);
    }

    /// <summary>Same door as <see cref="Load"/>, but reports the FFI call (native parse + JSON
    /// marshal across the P/Invoke boundary) and the JSON deserialize (native string -> RenderTree
    /// records) as two separate stopwatches instead of one combined total.</summary>
    public static LoadBreakdown LoadWithBreakdown(string path)
    {
        var extension = Path.GetExtension(path).TrimStart('.');
        var bytes = File.ReadAllBytes(path);

        var ffiWatch = Stopwatch.StartNew();
        string? json;
        OfficeDocumentHandle? handle = null;
        if (TextExtensions.Contains(extension))
        {
            json = ReadTextTree(bytes, extension);
        }
        else if (OfficeExtensions.Contains(extension))
        {
            (json, handle) = ReadOfficeTree(bytes, extension);
        }
        else
        {
            ffiWatch.Stop();
            return new LoadBreakdown(null,
                new RenderTreeError { Kind = "unsupportedExtension", Message = $"no reader for .{extension}" },
                ffiWatch.ElapsedMilliseconds, 0);
        }
        ffiWatch.Stop();

        if (json is null)
        {
            handle?.Dispose();
            var lastError = FastdocEngine.TakeLastError();
            return new LoadBreakdown(null,
                new RenderTreeError { Kind = "ffiFailure", Message = lastError ?? "no envelope returned" },
                ffiWatch.ElapsedMilliseconds, 0);
        }

        // Same handle-leak-on-throw handling as Load() above — see its comment.
        var deserializeWatch = Stopwatch.StartNew();
        var (tree, envelopeError) = RunDisposingOnThrow(handle, () =>
        {
            var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)
                ?? throw new InvalidOperationException("empty envelope JSON");
            if (envelope.Error is not null) { return (Tree: (RenderTree?)null, Error: envelope.Error); }
            var decoded = envelope.Ok!.Value.Deserialize<RenderTree>()
                ?? throw new InvalidOperationException("envelope.ok did not decode to a RenderTree");
            return (Tree: (RenderTree?)decoded, Error: (RenderTreeError?)null);
        });
        deserializeWatch.Stop();

        if (envelopeError is not null)
        {
            handle?.Dispose();
            return new LoadBreakdown(null, envelopeError, ffiWatch.ElapsedMilliseconds, deserializeWatch.ElapsedMilliseconds);
        }
        var successHandle = handle;
        handle = null;
        return new LoadBreakdown(tree, null, ffiWatch.ElapsedMilliseconds, deserializeWatch.ElapsedMilliseconds, successHandle, path);
    }

    private static string? ReadTextTree(byte[] bytes, string extension)
    {
        var ptr = FastdocEngine.fastdoc_read_text_tree(bytes, (nuint)bytes.Length,
            FastdocEngine.Utf8NulTerminated(extension));
        return FastdocEngine.TakeOwnedString(ptr);
    }

    /// <summary>Opens the document and reads its tree from the SAME handle, same as before —
    /// except the handle is no longer closed here. E2d: the caller now owns it (LoadResult.Handle
    /// / LoadBreakdown.Handle) so a picture can be fetched from this parse later, on demand,
    /// instead of every picture being decoded up front. A failed tree_json still closes the handle
    /// immediately (returned as null,null) since nothing else will ever query it.</summary>
    private static (string? Json, OfficeDocumentHandle? Handle) ReadOfficeTree(byte[] bytes, string extension)
    {
        // E2c-1: the measurer + font-provider ports MUST be installed before the first
        // fastdoc_office_open — opening a real document with neither installed used to succeed and
        // then panic inside the engine on the first band query (RustOfficeDocumentHandle.swift's
        // own measured note, mirrored here). Install() is idempotent, so every open pays this once.
        Paging.TextMeasurerPort.Install();
        var extensionBytes = FastdocEngine.Utf8NulTerminated(extension);
        var rawHandle = FastdocEngine.fastdoc_office_open(bytes, (nuint)bytes.Length, extensionBytes);
        if (rawHandle == IntPtr.Zero)
        {
            return (null, null);
        }
        var handle = new OfficeDocumentHandle(rawHandle);
        var ptr = FastdocEngine.fastdoc_office_tree_json(rawHandle, bytes, (nuint)bytes.Length);
        var json = FastdocEngine.TakeOwnedString(ptr);
        if (json is null)
        {
            handle.Dispose();
            return (null, null);
        }
        return (json, handle);
    }
}
