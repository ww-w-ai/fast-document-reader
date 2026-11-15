using System;
using System.IO;
using System.Net;
using System.Text.Json;

namespace FastDoc.Avalonia.WebRender;

/// <summary>Builds the one self-contained HTML page a <see cref="IWebBlockRenderer"/> loads to
/// typeset a block — shared by every engine (WebView2, WebKitGTK, on-demand Chromium) so there is
/// exactly one place that embeds mermaid.min.js/katex.min.js, matching the SAME assets macOS's
/// WebBlock.swift loads (Resources/mermaid.min.js, Resources/katex.min.js + katex-inlined.min.css)
/// rather than each renderer growing its own copy that could drift in behaviour.</summary>
public static class WebRenderHtml
{
    public static string Build(WebBlockRequest request, string mermaidJsPath, string katexJsPath, string katexCssPath)
    {
        return request.Engine switch
        {
            WebBlockEngine.Mermaid => BuildMermaidHtml(request.Code, mermaidJsPath),
            WebBlockEngine.Math => BuildKatexHtml(request.Code, katexJsPath, katexCssPath),
            _ => throw new ArgumentOutOfRangeException(nameof(request)),
        };
    }

    private static string BuildMermaidHtml(string diagramSource, string mermaidJsPath)
    {
        var mermaidJs = ReadIfExists(mermaidJsPath);
        var encodedDiagram = WebUtility.HtmlEncode(diagramSource);
        return $$"""
            <!doctype html><html><head><meta charset="utf-8">
            <script>{{mermaidJs}}</script></head>
            <body><div id="target" class="mermaid">{{encodedDiagram}}</div>
            <script>mermaid.initialize({ startOnLoad: true });</script></body></html>
            """;
    }

    private static string BuildKatexHtml(string tex, string katexJsPath, string katexCssPath)
    {
        var katexJs = ReadIfExists(katexJsPath);
        var katexCss = ReadIfExists(katexCssPath);
        var jsonTex = JsonSerializer.Serialize(tex);
        return $$"""
            <!doctype html><html><head><meta charset="utf-8">
            <style>{{katexCss}}</style><script>{{katexJs}}</script></head>
            <body><div id="target"></div>
            <script>
              katex.render({{jsonTex}}, document.getElementById('target'),
                { throwOnError: false, displayMode: true });
            </script></body></html>
            """;
    }

    private static string ReadIfExists(string path) => File.Exists(path) ? File.ReadAllText(path) : "";
}
