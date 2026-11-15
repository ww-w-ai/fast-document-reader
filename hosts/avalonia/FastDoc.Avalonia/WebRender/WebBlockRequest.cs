namespace FastDoc.Avalonia.WebRender;

/// <summary>Which JS engine draws a <see cref="WebBlockRequest"/> — mirrors the macOS vocabulary
/// (<c>WebBlock.Engine</c> in <c>Sources/FastDocReader/Render/WebBlock.swift</c>) on purpose: both
/// hosts feed the same two source languages (a mermaid diagram definition, a TeX/LaTeX formula)
/// into whatever real browser engine is available, so the request shape stays identical even
/// though the two hosts pick that engine differently.</summary>
public enum WebBlockEngine
{
    Mermaid,
    Math,
}

/// <summary>One block a real browser engine would need to typeset — the mermaid source or the TeX
/// this host currently shows as raw text (see <c>FlowDocumentBuilder</c>'s "codeBlock" and
/// "formula" cases). Carries no rendering state of its own; a renderer is handed one of these and
/// returns PNG bytes or throws.</summary>
public sealed record WebBlockRequest(WebBlockEngine Engine, string Code);
