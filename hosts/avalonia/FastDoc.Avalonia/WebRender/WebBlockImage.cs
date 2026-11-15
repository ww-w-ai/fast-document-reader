namespace FastDoc.Avalonia.WebRender;

/// <summary>What byte shape a rendered block came back as — NOT always PNG. Discovered while
/// wiring the real APIs: Windows' WebView2 (<c>CapturePreviewAsync</c>) and the on-demand
/// Chromium path (PuppeteerSharp's element screenshot) both hand back PNG bytes directly, but
/// Avalonia.Controls.WebView's Linux/GTK backend exposes NO pixel-screenshot method at all — only
/// <c>PrintToPdfStreamAsync</c> (confirmed by reading the package's own metadata; the "offscreen
/// rendering is experimental" caveat s12e-web-render-decision.md already quoted turns out to mean
/// "there is no stable screenshot API", not merely "the stable one is flaky"). Forcing every
/// renderer to answer with PNG would have meant lying about what the Linux path actually
/// produces, or rasterizing a PDF page to PNG inside this class for no architectural reason — the
/// consumer (whatever eventually turns this into an on-screen image block) can decide how to
/// handle each format, the same way this app already caches vector PDF on macOS
/// (Cache/MermaidCache.swift) rather than a raster image.</summary>
public enum WebImageFormat
{
    Png,
    Pdf,
}

public sealed record WebBlockImage(byte[] Bytes, WebImageFormat Format);
