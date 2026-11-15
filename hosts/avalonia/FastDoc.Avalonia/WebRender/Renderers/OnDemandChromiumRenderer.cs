using System;
using System.Threading;
using System.Threading.Tasks;
using PuppeteerSharp;

namespace FastDoc.Avalonia.WebRender.Renderers;

/// <summary>
/// S12-F's common fallback: a headless Chromium fetched on demand via PuppeteerSharp, used only
/// when the opt-in switch is on and no native engine (WebView2 on Windows, WebKitGTK on Linux)
/// worked. Chosen over Playwright.NET per PM's S12-F judgment 3: PuppeteerSharp drives a real
/// Chromium process directly over the DevTools protocol with no bundled Node.js runtime, whereas
/// Playwright.NET's own installer script runs on a bundled Node.js driver (see
/// s12f-scope-v2.md's "확정 필요" section — this is the resolution of that open item).
///
/// UNVERIFIED ON THIS DEVELOPMENT MACHINE: this class compiles and its API calls match
/// PuppeteerSharp 25.8.0's public surface as restored into this repo's NuGet cache, but no test in
/// this repo actually downloads or launches Chromium — that network- and OS-shaped operation is a
/// QA task on the real target platform (Windows/Linux), not something a unit test should attempt.
/// </summary>
public sealed class OnDemandChromiumRenderer : IWebBlockRenderer
{
    /// <summary>Same asset bundle macOS's WebKit renderer loads (Resources/mermaid.min.js,
    /// Resources/katex.min.js + katex-inlined.min.css) — see WebBlock.swift's own doc comment.
    /// Reusing the identical JS avoids a second rendering-fidelity surface to maintain.</summary>
    private readonly string _mermaidJsPath;
    private readonly string _katexJsPath;
    private readonly string _katexCssPath;

    public OnDemandChromiumRenderer(string mermaidJsPath, string katexJsPath, string katexCssPath)
    {
        _mermaidJsPath = mermaidJsPath;
        _katexJsPath = katexJsPath;
        _katexCssPath = katexCssPath;
    }

    public async Task<WebBlockImage> RenderAsync(WebBlockRequest request, CancellationToken cancellationToken)
    {
        // BrowserFetcher.DownloadAsync() is a no-op (returns immediately) once the revision is
        // already cached locally — this is what makes "on-demand" also mean "offline after the
        // first successful download", per s12f-scope-v2.md's offline-behaviour column.
        var fetcher = new BrowserFetcher();
        var installed = await fetcher.DownloadAsync().ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();

        await using var browser = await Puppeteer.LaunchAsync(new LaunchOptions
        {
            Headless = true,
            ExecutablePath = installed.GetExecutablePath(),
        }).ConfigureAwait(false);

        await using var page = await browser.NewPageAsync().ConfigureAwait(false);
        var html = WebRenderHtml.Build(request, _mermaidJsPath, _katexJsPath, _katexCssPath);
        await page.SetContentAsync(html).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();

        var element = await page.QuerySelectorAsync("#target").ConfigureAwait(false);
        if (element is null)
        {
            throw new InvalidOperationException("WebRender target element did not render.");
        }
        var png = await element.ScreenshotDataAsync(new ElementScreenshotOptions
        {
            Type = ScreenshotType.Png,
        }).ConfigureAwait(false);
        return new WebBlockImage(png, WebImageFormat.Png);
    }
}
