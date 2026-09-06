using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// A docx/odt is a zip container the reader otherwise trusts, so a crafted document with one
/// entry whose DEFLATE stream expands far past its compressed size (a classic zip bomb) could
/// exhaust memory decoding a single "picture" if ImageBlockRenderer.ZipEntryBytes copied it out
/// with no size limit. It caps both the entry's declared uncompressed Length (a cheap header
/// check) AND the actual bytes copied out (the real backstop, in case a crafted header understates
/// the true size) at 200MB, returning null — one image is skipped, not the whole document —
/// instead of reading further.
///
/// This test builds a REAL zip file with one entry that decompresses past that cap (a large run
/// of a single repeated byte compresses to a few KB, so the ON-DISK test fixture stays tiny even
/// though its declared uncompressed size is over 200MB) and proves the renderer treats it as a
/// decode failure (the placeholder path), not an attempted full read.
/// </summary>
public class ImageBlockRendererZipCapTests
{
    private const long OverCapUncompressedBytes = 201L * 1024 * 1024; // just over the renderer's 200MB cap

    [Fact]
    public void An_oversized_zip_entry_is_skipped_as_a_decode_failure_not_read_in_full()
    {
        var zipPath = Path.Combine(Path.GetTempPath(), $"fastdoc-zipbomb-test-{Guid.NewGuid():N}.docx");
        try
        {
            CreateZipWithOneHighlyCompressibleEntry(zipPath, "word/media/image1.png", OverCapUncompressedBytes);

            var tree = new RenderTree
            {
                SchemaVersion = 1,
                Resources = new List<ResourceWire>
                {
                    new() { Id = 1, MimeType = "image/png", SourceKey = "word/media/image1.png" },
                },
            };

            var renderer = new ImageBlockRenderer();
            renderer.Reset(tree);
            renderer.SetZipSource(zipPath, "docx");

            var decoded = renderer.TryDecode(1);

            Assert.False(decoded); // the cap kicked in -> ZipEntryBytes returned null -> placeholder path
            Assert.Equal(0, renderer.DecodeSuccessCount);
            Assert.Equal(1, renderer.DecodeFailureCount);
        }
        finally
        {
            File.Delete(zipPath);
        }
    }

    /// <summary>Writes a zip whose single entry, named <paramref name="entryName"/>, decompresses
    /// to <paramref name="uncompressedSize"/> bytes of a repeated pattern — Deflate collapses a
    /// long run of identical bytes to almost nothing, so this stays a small file on disk while
    /// still declaring (and actually containing, if fully inflated) a huge uncompressed size,
    /// exactly the shape of a real decompression-bomb zip entry.</summary>
    private static void CreateZipWithOneHighlyCompressibleEntry(string zipPath, string entryName, long uncompressedSize)
    {
        using var fileStream = new FileStream(zipPath, FileMode.Create, FileAccess.Write);
        using var archive = new ZipArchive(fileStream, ZipArchiveMode.Create);
        var entry = archive.CreateEntry(entryName, CompressionLevel.Optimal);
        using var entryStream = entry.Open();
        var chunk = new byte[1024 * 1024]; // all zeros; Deflate compresses this to almost nothing
        long written = 0;
        while (written < uncompressedSize)
        {
            var toWrite = (int)Math.Min(chunk.Length, uncompressedSize - written);
            entryStream.Write(chunk, 0, toWrite);
            written += toWrite;
        }
    }
}
