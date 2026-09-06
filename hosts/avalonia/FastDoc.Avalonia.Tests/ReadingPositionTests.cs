using System;
using System.IO;
using FastDoc.Avalonia.Reading;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// ReadingPositions (Reading/ReadingPosition.cs) persists to a fixed sibling of RecentFiles'
/// store, with no injection point — same reasoning as RecentFilesTests: back up whatever is
/// already there, run against the REAL store, restore it in `finally`/Dispose.
/// </summary>
public class ReadingPositionTests : IDisposable
{
    private readonly string _storePath = ReadingPositions.StorePath;
    private readonly string? _backupPath;
    private readonly bool _hadExistingStore;

    public ReadingPositionTests()
    {
        _hadExistingStore = File.Exists(_storePath);
        if (_hadExistingStore)
        {
            _backupPath = _storePath + $".test-backup-{Guid.NewGuid():N}";
            File.Copy(_storePath, _backupPath);
        }
        StartFromEmptyStore();
    }

    public void Dispose()
    {
        if (_hadExistingStore && _backupPath is not null)
        {
            File.Copy(_backupPath, _storePath, overwrite: true);
            File.Delete(_backupPath);
        }
        else if (!_hadExistingStore && File.Exists(_storePath))
        {
            File.Delete(_storePath);
        }
    }

    [Fact]
    public void Find_on_an_empty_store_returns_null()
    {
        Assert.Null(ReadingPositions.Find("some-key"));
    }

    [Fact]
    public void Save_then_Find_round_trips_block_index_fraction_and_zoom()
    {
        ReadingPositions.Save("doc-a", blockIndex: 42, fraction: 0.25, zoom: 1.5);

        var found = ReadingPositions.Find("doc-a");

        Assert.NotNull(found);
        Assert.Equal(42, found!.BlockIndex);
        Assert.Equal(0.25, found.Fraction, 3);
        Assert.Equal(1.5, found.Zoom, 3);
    }

    [Fact]
    public void Save_on_an_existing_key_replaces_it_instead_of_duplicating()
    {
        ReadingPositions.Save("doc-a", 10, 0.1, 1.0);
        ReadingPositions.Save("doc-a", 20, 0.9, 2.0);

        var found = ReadingPositions.Find("doc-a");

        Assert.NotNull(found);
        Assert.Equal(20, found!.BlockIndex);
        Assert.Equal(0.9, found.Fraction, 3);
        Assert.Equal(2.0, found.Zoom, 3);
    }

    [Fact]
    public void Save_clamps_fraction_into_0_to_1()
    {
        ReadingPositions.Save("doc-neg", 0, -0.5, 1.0);
        ReadingPositions.Save("doc-over", 0, 1.5, 1.0);

        Assert.Equal(0.0, ReadingPositions.Find("doc-neg")!.Fraction, 3);
        Assert.Equal(1.0, ReadingPositions.Find("doc-over")!.Fraction, 3);
    }

    [Fact]
    public void Save_trims_to_the_100_entry_limit_dropping_the_oldest()
    {
        for (var i = 0; i < 102; i++)
        {
            ReadingPositions.Save($"doc-{i}", i, 0.0, 1.0);
        }

        Assert.NotNull(ReadingPositions.Find("doc-101"));
        Assert.NotNull(ReadingPositions.Find("doc-2"));
        Assert.Null(ReadingPositions.Find("doc-0"));
        Assert.Null(ReadingPositions.Find("doc-1"));
    }

    [Fact]
    public void Find_on_a_corrupt_store_file_returns_null_instead_of_throwing()
    {
        var dir = Path.GetDirectoryName(_storePath)!;
        Directory.CreateDirectory(dir);
        File.WriteAllText(_storePath, "{ not valid json ][");

        Assert.Null(ReadingPositions.Find("anything"));
    }

    [Fact]
    public void MakeKey_differs_for_the_same_path_with_different_file_content()
    {
        var path = Path.Combine(Path.GetTempPath(), $"fastdoc-position-test-{Guid.NewGuid():N}.md");
        try
        {
            File.WriteAllText(path, "one");
            var keyA = ReadingPositions.MakeKey(path);

            // Sleep past filesystem mtime granularity so the second write's timestamp differs —
            // MakeKey's whole point is that an overwritten file must not resume the old position.
            System.Threading.Thread.Sleep(1100);
            File.WriteAllText(path, "a very different and much longer body of text");
            var keyB = ReadingPositions.MakeKey(path);

            Assert.NotEqual(keyA, keyB);
        }
        finally
        {
            File.Delete(path);
        }
    }

    private void StartFromEmptyStore()
    {
        if (File.Exists(_storePath))
        {
            File.Delete(_storePath);
        }
    }
}
