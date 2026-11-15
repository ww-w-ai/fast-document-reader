namespace FastDoc.Avalonia.WebRender;

/// <summary>What <see cref="WebRenderCoordinator.RenderAsync"/> decided for one block — either the
/// raw source (the S12-F default state, not an error state: see s12f-scope-v2.md "raw는 실패가
/// 아니라 설계된 기본값") or PNG bytes from whichever engine in the chain succeeded first.</summary>
public abstract record WebRenderResult
{
    public sealed record Raw(string Source) : WebRenderResult;

    public sealed record Rendered(WebBlockImage Image, string EngineName) : WebRenderResult;

    public static WebRenderResult AsRaw(string source) => new Raw(source);

    public static WebRenderResult AsRendered(WebBlockImage image, string engineName) => new Rendered(image, engineName);
}
