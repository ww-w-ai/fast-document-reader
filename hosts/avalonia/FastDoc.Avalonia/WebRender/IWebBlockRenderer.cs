using System.Threading;
using System.Threading.Tasks;

namespace FastDoc.Avalonia.WebRender;

/// <summary>Renders one mermaid/KaTeX block through a real browser engine, returning whatever
/// image format that engine actually produces (see <see cref="WebBlockImage"/> — not every engine
/// can produce PNG). Throws on any failure (missing runtime, navigation error, capture error) — it
/// never returns a "failed" sentinel, because <see cref="WebRenderCoordinator"/> treats an
/// exception and a timeout identically: try the next candidate in the chain.</summary>
public interface IWebBlockRenderer
{
    Task<WebBlockImage> RenderAsync(WebBlockRequest request, CancellationToken cancellationToken);
}
