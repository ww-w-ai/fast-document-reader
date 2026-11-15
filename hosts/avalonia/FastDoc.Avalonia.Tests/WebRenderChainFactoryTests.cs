using FastDoc.Avalonia.WebRender;

namespace FastDoc.Avalonia.Tests;

/// <summary>Pins the pure platform→engine-order POLICY (PM's S12-F judgments 1 and 2), separate
/// from any real capability probe or renderer — see <see cref="WebRenderChainFactory"/>'s own doc
/// comment for why this split exists.</summary>
public class WebRenderChainFactoryTests
{
    [Fact]
    public void Windows_tries_its_native_WebView2_engine_before_falling_back_to_on_demand_chromium()
    {
        var chain = WebRenderChainFactory.ForWindows();

        Assert.Equal(new[] { WebRenderEngineKind.WindowsWebView2, WebRenderEngineKind.OnDemandChromium }, chain);
    }

    [Fact]
    public void Linux_tries_WebKitGtk_first_per_PM_judgment_2_before_falling_back_to_on_demand_chromium()
    {
        var chain = WebRenderChainFactory.ForLinux();

        Assert.Equal(new[] { WebRenderEngineKind.LinuxWebKitGtk, WebRenderEngineKind.OnDemandChromium }, chain);
    }

    [Fact]
    public void An_untargeted_platform_still_gets_the_common_fallback_rather_than_an_empty_chain()
    {
        var chain = WebRenderChainFactory.ForOther();

        Assert.Equal(new[] { WebRenderEngineKind.OnDemandChromium }, chain);
    }
}
