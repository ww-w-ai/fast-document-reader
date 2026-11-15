using System;
using System.IO;

namespace FastDoc.Avalonia.WebRender;

/// <summary>Where the bundled mermaid/KaTeX assets land next to the built binary — see
/// `FastDoc.Avalonia.csproj`'s own `Assets/WebRender/*` `CopyToOutputDirectory` items. Kept as one
/// resolver so every caller (the coordinator wiring, tests) agrees on the same three paths rather
/// than each hardcoding `AppContext.BaseDirectory` joins of its own.</summary>
public static class WebRenderAssets
{
    public static string MermaidJsPath => Path.Combine(AppContext.BaseDirectory, "Assets", "WebRender", "mermaid.min.js");
    public static string KatexJsPath => Path.Combine(AppContext.BaseDirectory, "Assets", "WebRender", "katex.min.js");
    public static string KatexCssPath => Path.Combine(AppContext.BaseDirectory, "Assets", "WebRender", "katex-inlined.min.css");
}
