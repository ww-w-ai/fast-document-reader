using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.TextFormatting;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Printing;

namespace FastDoc.Avalonia.Rendering;

/// <summary>Decodes a RenderTree picture resource into a real Avalonia bitmap and draws it scaled
/// the way the macOS reader scales one — CLAUDE.md invariant 46: "a graphic is scaled by the
/// reading column over the DOCUMENT's own page width", not by a fixed app rhythm, so ⌘+/⌘− (the
/// text zoom) never resizes a picture; only the window's own width does, exactly like this host's
/// text column already behaves.
///
/// A resource is looked up ONCE per document (by resource id, not per draw) and its decoded
/// Bitmap is cached — SetTree resets the cache, so a document swap never serves another
/// document's pixels, and a picture used many times in one document decodes once.</summary>
public sealed class ImageBlockRenderer
{
    private static readonly Color PlaceholderFillColor = Color.FromArgb(0x20, 0x60, 0x8a, 0xc0);
    private static readonly Color PlaceholderStrokeColor = Color.FromRgb(0x60, 0x8a, 0xc0);

    /// <summary>S5-C2: the decoded <see cref="Bitmap"/> alongside the document's OWN encoded bytes
    /// and declared MIME type (or a magic-byte sniff of those bytes when the declared MIME is
    /// missing/wrong — see <see cref="SniffMimeType"/>) — a PDF export can embed a JPEG source as
    /// JPEG instead of decoding then re-encoding it, see <see cref="IPageCanvas.DrawImage"/>'s own
    /// doc. Screen drawing never looks past the Bitmap field.</summary>
    private readonly Dictionary<ulong, (Bitmap? Bitmap, byte[]? Bytes, string? MimeType)> _cache = new();
    private Dictionary<ulong, ResourceWire> _resourcesById = new();
    private OfficeDocumentHandle? _handle;
    private ZipArchive? _zip;

    /// <summary>S8-D2 (D2-d): the CURRENT document's own directory — every relative markdown image
    /// URL (<c>![alt](assets/pic.jpg)</c>) resolves against this, the same rule a browser or
    /// swift-markdown's own image loader applies. Set unconditionally by <see cref="SetZipSource"/>
    /// (every caller already passes the document's path there for every format, not only docx/odt),
    /// so markdown needs no separate wiring even though it never opens that path as a zip.</summary>
    private string? _documentDirectory;

    public int DecodeSuccessCount { get; private set; }
    public int DecodeFailureCount { get; private set; }

    /// <summary>Rebinds this renderer to a new document's resource table and drops every cached
    /// bitmap — called from FlowDocumentView.SetTree so a stale decode never survives a document
    /// swap (resource ids are only unique WITHIN one tree). Also clears the E2d handle binding and
    /// the docx/odt zip archive (see <see cref="SetZipSource"/>) — a caller that wants lazy fetch
    /// for THIS document must call SetHandle/SetZipSource again after Reset.</summary>
    public void Reset(RenderTree? tree)
    {
        _cache.Clear();
        DecodeSuccessCount = 0;
        DecodeFailureCount = 0;
        _resourcesById = new Dictionary<ulong, ResourceWire>();
        _handle = null;
        _zip?.Dispose();
        _zip = null;
        _documentDirectory = null;
        LastResolvedUriListPath = null;
        LastResolvedUriListByteLength = null;
        if (tree is null) { return; }
        foreach (var resource in tree.Resources)
        {
            _resourcesById[resource.Id] = resource;
        }
    }

    /// <summary>E2d: binds this renderer to the open office parse behind the CURRENT document, so
    /// a resource with no eager bytes (BytesBase64 null, sourceKey present — the P2c shape) can be
    /// decoded on demand from the still-open handle instead of never at all. Call after Reset, for
    /// the same document Reset just bound; null for markdown/text and for a document whose parse
    /// keeps no live handle (docx/odt today — their pictures ship eagerly in BytesBase64 instead,
    /// per fastdoc_office_image_base64's own "ask elsewhere" contract for those formats).</summary>
    public void SetHandle(OfficeDocumentHandle? handle)
    {
        _handle = handle;
    }

    /// <summary>docx/odt shape (CLAUDE.md: "their pictures come from the zip the host holds") —
    /// opens the document's OWN file as a zip archive, once per document, so a resource with a
    /// sourceKey but no eager bytes and no engine handle (fastdoc_office_image_base64 answers nil
    /// for docx/odt — no live parse to ask) can still be found: the sourceKey IS the archive entry
    /// path (docx: "word/media/image1.png"; odt: "Pictures/xyz.png"), the same key the macOS
    /// reader's `ZipArchive.data(for:)` uses. Call after Reset, for the same document Reset just
    /// bound; pass null/anything else to skip (hwp/hwpx keep no archive at all — rhwp reads them
    /// from raw bytes, and their pictures come back through SetHandle instead). Never throws: a
    /// path that isn't actually a zip (or doesn't exist any more) just leaves lazy fetch unable to
    /// find anything, same as a missing handle.</summary>
    public void SetZipSource(string? path, string? extension)
    {
        if (path is null) { return; }
        // Every caller (MainWindow, the headless --pdf/--extract entry points, PdfExporter) passes
        // the document's OWN path here for every format, so this is also where a markdown/text
        // document's directory becomes known — the extension gate below only decides whether it is
        // ALSO worth opening as a zip.
        try { _documentDirectory = Path.GetDirectoryName(Path.GetFullPath(path)); }
        catch { _documentDirectory = null; }

        if (extension is null) { return; }
        var ext = extension.TrimStart('.').ToLowerInvariant();
        if (ext is not ("docx" or "docm" or "dotx" or "dotm" or "odt")) { return; }
        try
        {
            var stream = File.OpenRead(path);
            _zip = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen: false);
        }
        catch
        {
            _zip = null;
        }
    }

    /// <summary>A docx/odt is a zip the reader trusts only as far as "well-formed
    /// container" — an attacker can still declare one entry (a "picture") whose DEFLATE stream
    /// expands far past its compressed size (a zip bomb). Two independent gates below use this:
    /// the entry's OWN declared uncompressed <c>Length</c> (a zip-header field, so a crafted
    /// header could understate it) is checked first as a cheap reject, and the actual byte count
    /// copied out is checked AGAIN as the real backstop regardless of what the header claimed.</summary>
    private const long MaxImageEntryBytes = 200L * 1024 * 1024; // 200MB — generous for any real picture

    /// <summary>Looks up `key` (a zip entry path) in the currently-open archive. Tries an exact
    /// match first (the common case — the sourceKey IS the entry's FullName), then a
    /// case-insensitive / separator-normalized scan for a document whose sourceKey and archive
    /// disagree only in case or in `\` vs `/`. Returns null for no archive, no match, an entry
    /// whose declared or actual size exceeds <see cref="MaxImageEntryBytes"/> (a would-be
    /// decompression bomb — that ONE image is skipped, not the whole document), or a read failure
    /// (a corrupt entry) — never throws.</summary>
    private byte[]? ZipEntryBytes(string key)
    {
        if (_zip is null) { return null; }
        try
        {
            var entry = _zip.GetEntry(key);
            if (entry is null)
            {
                var normalizedKey = key.Replace('\\', '/').TrimStart('/');
                entry = _zip.Entries.FirstOrDefault(e =>
                    string.Equals(e.FullName.Replace('\\', '/').TrimStart('/'), normalizedKey,
                        StringComparison.OrdinalIgnoreCase));
            }
            if (entry is null) { return null; }
            if (entry.Length > MaxImageEntryBytes) { return null; } // header-declared size, cheap reject

            using var entryStream = entry.Open();
            using var memory = new MemoryStream();
            var buffer = new byte[81920];
            long total = 0;
            int read;
            while ((read = entryStream.Read(buffer, 0, buffer.Length)) > 0)
            {
                total += read;
                if (total > MaxImageEntryBytes) { return null; } // actual bytes, regardless of the header
                memory.Write(buffer, 0, read);
            }
            return memory.ToArray();
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Draws the block's picture at pixel position (left, top), scaled to fit within
    /// `columnWidth` (or the document's own declared width, whichever is smaller) while preserving
    /// aspect ratio, honouring the block's paragraph alignment. Returns the drawn height in pixels.
    /// Falls back to the placeholder box — never throws — when the resource id is absent, unknown,
    /// or its bytes fail to decode as an image.
    ///
    /// S8-A2 (C2): size comes ONLY from <see cref="PictureGeometry.Measure(double,double,double)"/>
    /// fed the EFFECTIVE declared size (<see cref="EffectiveDeclaredSize"/>) — the document's own
    /// authored size clamped to the column, exactly what <see
    /// cref="Paging.PageLayout.NonTextBlockHeightPoints"/> and <see cref="FlowDocumentView"/>'s own
    /// EstimateHeight already reserved space for using the SAME method. This method used to
    /// re-derive height from the DECODED bitmap's own pixel aspect ratio when one was available,
    /// which could disagree with the reserved height and let a picture overlap the block drawn
    /// after it (catalog finding F3/C2) — invariant 46 is explicit that reflow must never depend on
    /// decoded pixels for a block that DECLARED a real size. A markdown image never does (S8-D2:
    /// the producer emits an honest {0,0} — see <see cref="EffectiveDeclaredSize"/>'s own doc for
    /// why the bitmap is the only remaining source of truth in exactly that one case).</summary>
    public double Draw(IPageCanvas surface, FlowBlock block, double left, double top, double columnWidth, double indentPx)
    {
        var maxWidth = Math.Max(20, columnWidth - indentPx);
        var maxWidthPoints = maxWidth / PointsToPixels;
        var (declaredWidthPoints, declaredHeightPoints) = EffectiveDeclaredSize(block);
        var (widthPoints, heightPoints) = PictureGeometry.Measure(declaredWidthPoints, declaredHeightPoints, maxWidthPoints);
        var drawWidth = widthPoints * PointsToPixels;
        var drawHeight = heightPoints * PointsToPixels;

        var resolved = block.ImageResourceId is { } id ? Resolve(id) : default;
        var bitmap = resolved.Bitmap;

        var x = left + indentPx + AlignmentOffset(block.Alignment, maxWidth, drawWidth);
        var rect = new Rect(x, top, drawWidth, drawHeight);

        if (bitmap is not null)
        {
            surface.DrawImage(bitmap, resolved.Bytes, resolved.MimeType, rect);
        }
        else
        {
            surface.DrawRect(rect, PlaceholderFillColor, PlaceholderStrokeColor, 1);
            if (block.PlaceholderLabel is { Length: > 0 } label)
            {
                DrawPlaceholderLabel(surface, label, rect);
            }
        }

        return drawHeight;
    }

    /// <summary>Decodes (and caches) one resource without drawing it — lets a caller confirm
    /// decode success/failure counts (DecodeSuccessCount/DecodeFailureCount) without needing a
    /// live DrawingContext, e.g. the S4/E2b measurement harness.</summary>
    public bool TryDecode(ulong resourceId) => Resolve(resourceId).Bitmap is not null;

    /// <summary>S9-B3 batch 6 (#45, mirrors DiagramZoomWindow.swift on macOS): the decoded bitmap
    /// for a resource id — null when it has not decoded (a lazy docx/odt picture whose bytes have
    /// not been fetched yet, or a genuine decode failure) — used by the click-to-enlarge feature to
    /// show the SAME bitmap this renderer already draws inline, not a second decode of the raw
    /// bytes.</summary>
    public Bitmap? ResolveBitmap(ulong resourceId) => Resolve(resourceId).Bitmap;

    /// <summary>S8-D2 (D2-d): the declared width/height (in points) a block's picture should be
    /// MEASURED at — the block's own declared size when it stated one (&gt; 0 on both axes), or
    /// else the DECODED bitmap's own pixel size converted to points at 96dpi. The markdown producer
    /// (rust/crates/fastdoc-engine/src/render/markdown/mod.rs, resolve_image_resource) never
    /// resolves an image's real dimensions — it has no filesystem mandate at parse time — and ships
    /// an honest <c>{0, 0}</c> intrinsic size instead of a guess; every OTHER format's adapter
    /// (docx/odt/hwp) always states a real size, so this fallback is reached ONLY for that one
    /// producer's pictures.
    ///
    /// Calling this decodes (and caches, via <see cref="Resolve"/>) the resource exactly the way
    /// <see cref="Draw"/> already does, so a caller measuring space to RESERVE for a block before it
    /// is ever drawn (<see cref="FlowDocumentView"/>'s EstimateHeight) and <see cref="Draw"/> itself
    /// read the SAME size and can never disagree — the reserved-equals-drawn invariant <see
    /// cref="PictureGeometry"/>'s own doc requires (S8-A2 finding F3/C2). Returns the block's own
    /// declared numbers unchanged (even if 0) when no bitmap decodes, so <see
    /// cref="PictureGeometry.Measure(double,double,double)"/>'s own "0 falls back to a fixed
    /// placeholder box" rule still applies to an image this reader cannot fetch or decode.</summary>
    public (double WidthPoints, double HeightPoints) EffectiveDeclaredSize(FlowBlock block)
    {
        if (block.ImageWidthPoints is > 0 && block.ImageHeightPoints is > 0)
        {
            return (block.ImageWidthPoints.Value, block.ImageHeightPoints.Value);
        }
        var resolved = block.ImageResourceId is { } id ? Resolve(id) : default;
        if (resolved.Bitmap is { } bitmap && bitmap.PixelSize.Width > 0 && bitmap.PixelSize.Height > 0)
        {
            return (bitmap.PixelSize.Width * PixelsToPoints96Dpi, bitmap.PixelSize.Height * PixelsToPoints96Dpi);
        }
        return (block.ImageWidthPoints ?? 0, block.ImageHeightPoints ?? 0);
    }

    private (Bitmap? Bitmap, byte[]? Bytes, string? MimeType) Resolve(ulong resourceId)
    {
        if (_cache.TryGetValue(resourceId, out var cached)) { return cached; }

        Bitmap? bitmap = null;
        byte[]? bytes = null;
        string? mimeType = null;
        if (_resourcesById.TryGetValue(resourceId, out var resource))
        {
            // Eager bytes win when present; otherwise fetch lazily by the document's OWN key
            // (sourceKey), never by the tree's numeric resourceId, which neither door accepts.
            // E2d's handle (hwp/hwpx — a live parse to ask) goes first; the docx/odt zip archive
            // (SetZipSource) is the fallback fastdoc_office_image_base64 itself names for those
            // two formats ("their pictures come from the zip the host holds").
            bytes = resource.BytesBase64 is { Length: > 0 } base64 ? TryDecodeBase64(base64) : null;
            // S8-D2 (D2-d): for this ONE mime type the bytes just decoded are not a picture at all
            // — they are the document's declared `src` STRING, RFC 2483's "this is a URI
            // reference" (resolve_image_resource's own doc). Re-resolve them into the picture's
            // REAL bytes (a local file read) before anything below tries to decode them as an
            // image; a resource that stays unresolved (a remote http(s) URL, a missing file) falls
            // through to the placeholder path exactly like any other undecodable resource.
            if (bytes is not null && string.Equals(resource.MimeType, "text/uri-list", StringComparison.OrdinalIgnoreCase))
            {
                bytes = ResolveUriListBytes(bytes);
            }
            if (bytes is null && resource.SourceKey is { Length: > 0 } key)
            {
                bytes = _handle?.ImageBytes(key) ?? ZipEntryBytes(key);
            }

            if (bytes is not null)
            {
                // The engine's own declared mimeType is often the generic
                // "application/octet-stream" (not merely empty), which would silently defeat the
                // JPEG-passthrough check downstream — so anything that ISN'T a real image/* value
                // gets the magic-byte sniff too, not just an empty string.
                mimeType = resource.MimeType.StartsWith("image/", StringComparison.OrdinalIgnoreCase)
                    ? resource.MimeType
                    : SniffMimeType(bytes) ?? resource.MimeType;
                // FMD_IMAGE_FORMAT_PROBE=1 dumps every resolved picture's format/size to stderr —
                // the "what does this document actually carry" number the image re-encode logic
                // is judged against (measurements.md). Same on/off convention as this repo's other
                // FMD_* corpus probes.
                if (Environment.GetEnvironmentVariable("FMD_IMAGE_FORMAT_PROBE") == "1")
                {
                    Console.Error.WriteLine($"imgprobe: id={resourceId} mime={mimeType} bytes={bytes.Length}");
                }
                try
                {
                    using var stream = new MemoryStream(bytes);
                    bitmap = new Bitmap(stream);
                    DecodeSuccessCount++;
                }
                catch
                {
                    // Malformed/unsupported bytes (or a mime type Avalonia's codec set does not
                    // cover) — leave bitmap null so the caller draws the placeholder. Never crash
                    // the reader over one bad picture.
                    bitmap = null;
                    DecodeFailureCount++;
                }
            }
            else
            {
                DecodeFailureCount++;
            }
        }
        else
        {
            DecodeFailureCount++;
        }

        var result = (bitmap, bytes, mimeType);
        _cache[resourceId] = result;
        return result;
    }

    /// <summary>S8-D2 (D2-d): turns a <c>text/uri-list</c> resource's bytes (the document's own
    /// <c>src</c> string, UTF-8) into the picture's real bytes — a LOCAL file read, resolved
    /// against <see cref="_documentDirectory"/> for a relative path, or the path a <c>file:</c> URL
    /// names outright. An <c>http(s)</c> URL (or one that resolves to nothing, or a read failure)
    /// returns null so the caller falls to the ordinary placeholder path — this reader never
    /// fetches a remote image, and never throws over a bad or missing one.</summary>
    /// <summary>S8-D2 (D2-b QA follow-up): the local file path the LAST <see
    /// cref="ResolveUriListBytes"/> call actually read bytes from — null when that call never
    /// reached a successful file read (a remote URL, a missing file, or the uri-list branch not
    /// entered at all). This exists because <c>TryDecode</c> succeeding is NOT evidence the
    /// uri-list branch ran: under the Avalonia headless test platform, <c>new Bitmap(stream)</c>
    /// decodes ANY bytes — including the raw URL string this branch exists to avoid feeding it —
    /// as a fixed 1x1 image and never throws, so a test that only checks "did it decode" cannot
    /// tell "read the real file" from "fed the decoder garbage that it accepted anyway" (measured
    /// while diagnosing that exact false pass). A test asserting THIS path (and <see
    /// cref="LastResolvedUriListByteLength"/>) against the real file instead is not fooled by that
    /// stub, because disabling the branch leaves both null.</summary>
    public string? LastResolvedUriListPath { get; private set; }

    /// <summary>The byte count last read from <see cref="LastResolvedUriListPath"/> — paired with
    /// that path as branch-entry evidence; see its own doc.</summary>
    public long? LastResolvedUriListByteLength { get; private set; }

    private byte[]? ResolveUriListBytes(byte[] uriListBytes)
    {
        // Reset first — a failed resolution (remote URL, missing file) for THIS resource must not
        // leave a previous resource's path/length behind as if it were still current.
        LastResolvedUriListPath = null;
        LastResolvedUriListByteLength = null;

        string url;
        try { url = Encoding.UTF8.GetString(uriListBytes).Trim(); }
        catch { return null; }
        if (url.Length == 0) { return null; }

        if (url.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
            || url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            return null; // remote — stays a placeholder, deliberately never fetched
        }

        string localPath;
        if (Uri.TryCreate(url, UriKind.Absolute, out var absolute) && absolute.IsFile)
        {
            localPath = absolute.LocalPath;
        }
        else if (_documentDirectory is not null)
        {
            localPath = Path.GetFullPath(Path.Combine(_documentDirectory, Uri.UnescapeDataString(url)));
        }
        else
        {
            return null; // a relative path with no known document directory to resolve it against
        }

        try
        {
            var info = new FileInfo(localPath);
            if (!info.Exists || info.Length > MaxImageEntryBytes) { return null; } // same 200MB cap as ZipEntryBytes
            var bytes = File.ReadAllBytes(localPath);
            LastResolvedUriListPath = localPath;
            LastResolvedUriListByteLength = bytes.Length;
            return bytes;
        }
        catch
        {
            return null;
        }
    }

    private static byte[]? TryDecodeBase64(string base64)
    {
        try { return Convert.FromBase64String(base64); }
        catch { return null; }
    }

    /// <summary>S5-C2: the document's declared MIME can be missing or wrong (measured — some
    /// resources arrive with an empty <c>mimeType</c>), so this sniffs the first bytes' magic
    /// number instead of trusting it blindly. Covers the formats Avalonia's own image codec set
    /// decodes (see the reader's supported picture formats) — falls through to "unknown"
    /// (<c>null</c>) for anything else, which a PDF-export path treats as "always re-encode".</summary>
    private static string? SniffMimeType(byte[] bytes)
    {
        if (bytes.Length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) { return "image/jpeg"; }
        if (bytes.Length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) { return "image/png"; }
        if (bytes.Length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) { return "image/bmp"; }
        if (bytes.Length >= 6 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) { return "image/gif"; }
        if (bytes.Length >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
            && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) { return "image/webp"; }
        return null;
    }

    /// <summary>S8-A2 (C1): the "[ole]"/"[unsupported]" card's label, centered in the reserved
    /// placeholder box — the same visual role macOS's `OfficeTextBuilder.drawPlaceholderCard` plays
    /// for an OLE object/chart/SmartArt it cannot draw for real. Reuses <see
    /// cref="IPageCanvas.DrawTextLayout"/> (already in the interface for ordinary text) rather than
    /// adding a new canvas primitive — a label is just centered text over a rect this method
    /// already drew.</summary>
    private static void DrawPlaceholderLabel(IPageCanvas surface, string label, Rect rect)
    {
        var fontSize = Math.Clamp(rect.Height * 0.18, 7, 14);
        var layout = new TextLayout($"[{label}]", PlaceholderLabelTypeface, fontSize,
            PlaceholderLabelBrush, TextAlignment.Center, TextWrapping.NoWrap, maxWidth: Math.Max(1, rect.Width));
        var y = rect.Top + Math.Max(0, (rect.Height - layout.Height) / 2);
        surface.DrawTextLayout(layout, new Point(rect.Left, y));
    }

    private static readonly Typeface PlaceholderLabelTypeface = new("Inter");
    private static readonly IBrush PlaceholderLabelBrush = new SolidColorBrush(Color.FromRgb(0x60, 0x60, 0x60));

    private static double AlignmentOffset(TextAlignment alignment, double columnWidth, double drawWidth) => alignment switch
    {
        TextAlignment.Center => Math.Max(0, (columnWidth - drawWidth) / 2),
        TextAlignment.Right => Math.Max(0, columnWidth - drawWidth),
        _ => 0,
    };

    private const double PointsToPixels = 96.0 / 72.0;
    private const double PixelsToPoints96Dpi = 72.0 / 96.0;
}
