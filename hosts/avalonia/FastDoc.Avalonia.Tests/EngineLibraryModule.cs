using System;
using System.IO;
using System.Runtime.CompilerServices;

namespace FastDoc.Avalonia.Tests;

/// <summary>Page mode asks the engine's page plan where every block goes, so the managed paging
/// tests need the engine library the way the real-document tests always have. When
/// FASTDOC_ENGINE_LIB is not set, point it at the library `Scripts/build-engine-xplat.sh` left in
/// the repo for this machine — the gate then needs no ceremony beyond building the engine first.</summary>
internal static class EngineLibraryModule
{
    [ModuleInitializer]
    internal static void PointAtTheBuiltEngine()
    {
        if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("FASTDOC_ENGINE_LIB"))) { return; }
        var (folder, file) =
            OperatingSystem.IsWindows() ? ("windows-x64", "fastdoc_engine_ffi.dll")
            : OperatingSystem.IsMacOS() ? ("macos-arm64", "libfastdoc_engine_ffi.dylib")
            : ("linux-x64", "libfastdoc_engine_ffi.so");
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "rust", "dist", "xplat", folder, file);
            if (File.Exists(candidate))
            {
                Environment.SetEnvironmentVariable("FASTDOC_ENGINE_LIB", candidate);
                return;
            }
        }
    }
}
