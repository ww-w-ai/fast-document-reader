using System.Runtime.CompilerServices;

// S12-F: lets FastDoc.Avalonia.Tests exercise a small number of `internal` test seams (currently
// WebKitGtkCapabilityProbe's injectable dlopen check) that exist purely so this repo's own test
// project can pin selection logic no real Linux/WebKitGTK install is available to exercise on this
// (macOS) development machine — see that class's own doc comment. Not a general API surface.
[assembly: InternalsVisibleTo("FastDoc.Avalonia.Tests")]
