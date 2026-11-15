using System;
using System.IO;
using FastDoc.Avalonia.WebRender;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// WebRenderSettings (WebRender/WebRenderSettings.cs) persists to a fixed OS-standard path, same
/// as <c>RecentFiles</c>'s own store — these tests back up whatever is already there, run against
/// the real store, and restore it in a `finally`/<see cref="Dispose"/>, mirroring
/// <c>RecentFilesTests</c>'s own isolation pattern exactly.
/// </summary>
public class WebRenderSettingsTests : IDisposable
{
    private readonly string _storePath = WebRenderSettings.StorePath;
    private readonly string? _backupPath;
    private readonly bool _hadExistingStore;

    public WebRenderSettingsTests()
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
            File.Delete(_storePath);
        }
    }

    private void RemoveStoreIfPresent()
    {
        if (File.Exists(_storePath)) { File.Delete(_storePath); }
    }

    [Fact]
    public void A_fresh_install_with_no_store_file_defaults_rendering_to_off()
    {
        // This IS the S12-F product decision, not an incidental default: a fresh install must
        // never fetch a browser runtime or render a diagram before the user opts in (see
        // docs/studio/sprints/S12/s12f-scope-v2.md "기본 상태 재정의").
        RemoveStoreIfPresent();

        var loaded = WebRenderSettings.Load();

        Assert.False(loaded.RenderingEnabled);
    }

    [Fact]
    public void Save_then_load_round_trips_the_enabled_flag()
    {
        RemoveStoreIfPresent();

        WebRenderSettings.Save(new WebRenderSettingsData { RenderingEnabled = true });
        var loaded = WebRenderSettings.Load();

        Assert.True(loaded.RenderingEnabled);
    }

    [Fact]
    public void Turning_the_switch_back_off_and_reloading_reflects_off()
    {
        RemoveStoreIfPresent();
        WebRenderSettings.Save(new WebRenderSettingsData { RenderingEnabled = true });

        WebRenderSettings.Save(new WebRenderSettingsData { RenderingEnabled = false });
        var loaded = WebRenderSettings.Load();

        Assert.False(loaded.RenderingEnabled);
    }

    [Fact]
    public void A_corrupt_store_file_degrades_to_the_safe_off_default_instead_of_throwing()
    {
        var dir = Path.GetDirectoryName(_storePath);
        if (!string.IsNullOrEmpty(dir)) { Directory.CreateDirectory(dir); }
        File.WriteAllText(_storePath, "{ not valid json ][");

        var loaded = WebRenderSettings.Load();

        Assert.False(loaded.RenderingEnabled);
    }
}
