using System.Text.Json.Serialization;

namespace FastDoc.Avalonia.WebRender;

/// <summary>
/// S12-F2 (PM 2026-09-07, docs/studio/sprints/S12/s12f-web-render-optin.md §9-9/§9-10): the tiny
/// file-based IPC contract between <see cref="Renderers.ProcessIsolatedWebKitGtkRenderer"/> (the
/// parent, this app's normal process) and Program.cs's <c>--webrender-worker</c> headless door
/// (the disposable child process that actually constructs a <c>NativeWebView</c>). Kept as plain
/// JSON files, not stdin/stdout pipes: a native abort (SIGABRT) can tear the child down mid-write,
/// and a half-written file is trivially detected (missing, or fails to deserialize) — a half-
/// flushed pipe write is a subtler failure mode this contract does not need to reason about.
/// </summary>
public sealed class WebRenderWorkerRequest
{
    [JsonPropertyName("engine")] public string Engine { get; set; } = "";
    [JsonPropertyName("code")] public string Code { get; set; } = "";
}

public sealed class WebRenderWorkerResponse
{
    [JsonPropertyName("format")] public string Format { get; set; } = "";
    [JsonPropertyName("bytesBase64")] public string BytesBase64 { get; set; } = "";
}
