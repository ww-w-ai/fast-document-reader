using System;
using System.IO;
using System.Linq;
using FastDoc.Avalonia.Open;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// RecentFiles (Open/RecentFiles.cs) persists to a FIXED OS-standard path (StorePath has no
/// injection point — by design, so the location cannot drift under an env-var override; see that
/// file's own doc comment). These tests therefore back up whatever is already there, run against
/// the REAL store, and restore it in a `finally` — never leaving the developer's/CI machine with
/// altered recent-documents state, whatever the test outcome.
/// </summary>
public class RecentFilesTests : IDisposable
{
    private readonly string _storePath = RecentFiles.StorePath;
    private readonly string? _backupPath;
    private readonly bool _hadExistingStore;

    public RecentFilesTests()
    {
        _hadExistingStore = File.Exists(_storePath);
        if (_hadExistingStore)
        {
            _backupPath = _storePath + $".test-backup-{Guid.NewGuid():N}";
            File.Copy(_storePath, _backupPath);
        }
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
            // The test created the store where none existed before — remove it so the machine
            // ends the run exactly as it started.
            File.Delete(_storePath);
        }
    }

    [Fact]
    public void RecordOpened_on_an_empty_store_yields_a_single_entry()
    {
        StartFromEmptyStore();

        RecentFiles.RecordOpened("/tmp/fastdoc-recent-test/one.md");

        var entries = RecentFiles.Load();
        Assert.Single(entries);
        Assert.Equal("/tmp/fastdoc-recent-test/one.md", entries[0].Path);
    }

    [Fact]
    public void RecordOpened_moves_an_already_present_path_to_the_front_instead_of_duplicating_it()
    {
        StartFromEmptyStore();

        RecentFiles.RecordOpened("/tmp/fastdoc-recent-test/a.md");
        RecentFiles.RecordOpened("/tmp/fastdoc-recent-test/b.md");
        RecentFiles.RecordOpened("/tmp/fastdoc-recent-test/a.md"); // reopen a.md

        var entries = RecentFiles.Load();
        Assert.Equal(2, entries.Count); // not 3 — no duplicate
        Assert.Equal("/tmp/fastdoc-recent-test/a.md", entries[0].Path); // moved to front
        Assert.Equal("/tmp/fastdoc-recent-test/b.md", entries[1].Path);
    }

    [Fact]
    public void RecordOpened_trims_to_the_10_entry_limit_dropping_the_oldest()
    {
        StartFromEmptyStore();

        for (var i = 0; i < 12; i++)
        {
            RecentFiles.RecordOpened($"/tmp/fastdoc-recent-test/doc-{i}.md");
        }

        var entries = RecentFiles.Load();
        Assert.Equal(10, entries.Count);
        // Most-recently-opened (doc-11) is first; the two oldest (doc-0, doc-1) were dropped.
        Assert.Equal("/tmp/fastdoc-recent-test/doc-11.md", entries[0].Path);
        Assert.Equal("/tmp/fastdoc-recent-test/doc-2.md", entries[^1].Path);
        Assert.DoesNotContain(entries, e => e.Path is "/tmp/fastdoc-recent-test/doc-0.md" or "/tmp/fastdoc-recent-test/doc-1.md");
    }

    [Fact]
    public void Load_on_a_corrupt_store_file_returns_empty_instead_of_throwing()
    {
        var dir = Path.GetDirectoryName(_storePath)!;
        Directory.CreateDirectory(dir);
        File.WriteAllText(_storePath, "{ not valid json ][");

        var entries = RecentFiles.Load();

        Assert.Empty(entries);
    }

    [Fact]
    public void RecordOpened_treats_a_case_different_reopen_as_the_same_entry_on_Windows_and_macOS()
    {
        // APFS/NTFS resolve a path case-insensitively, so the SAME file opened once as
        // "Report.docx" and again as "report.docx" must land as one recent-files entry, not two.
        // PathComparisonPolicy decides this per-OS — assert the behavior this test's own platform
        // actually has, rather than assuming macOS/Windows, so this stays correct if it's ever run
        // on Linux CI.
        StartFromEmptyStore();

        RecentFiles.RecordOpened("/tmp/fastdoc-recent-test/Report.docx");
        RecentFiles.RecordOpened("/tmp/fastdoc-recent-test/report.DOCX"); // same file, different case

        var entries = RecentFiles.Load();
        var caseInsensitive = OperatingSystem.IsWindows() || OperatingSystem.IsMacOS();
        if (caseInsensitive)
        {
            Assert.Single(entries); // deduped -> moved to front, not appended as a second entry
            Assert.Equal("/tmp/fastdoc-recent-test/report.DOCX", entries[0].Path);
        }
        else
        {
            Assert.Equal(2, entries.Count); // Linux: genuinely two different files
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
