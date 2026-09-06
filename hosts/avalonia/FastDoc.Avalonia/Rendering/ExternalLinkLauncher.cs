using System.Diagnostics;

namespace FastDoc.Avalonia.Rendering;

/// <summary>S8-B4 (D2-c): the seam between "the user clicked an external link" and "the OS opens
/// it" — a small injectable port so a test can assert a link click WOULD have opened a given URL
/// without a real browser launching (the contract's own requirement). <see
/// cref="ProcessExternalLinkLauncher"/> is the only production implementation.</summary>
public interface IExternalLinkLauncher
{
    void Open(string url);
}

/// <summary>Opens a URL with whatever the OS registers as its default handler —
/// <c>UseShellExecute = true</c> is the cross-platform way to ask .NET to do this (it shells out
/// to <c>xdg-open</c>/<c>open</c>/the Windows shell under the hood, so this class does not need to
/// branch on <see cref="System.Runtime.InteropServices.RuntimeInformation"/> itself). Any failure
/// to launch (no registered handler, a malformed URL) is swallowed — the same "never crash the
/// reader over a best-effort side action" policy <see cref="FlowDocumentView.CopySelectionToClipboard"/>
/// already applies to a clipboard failure.</summary>
public sealed class ProcessExternalLinkLauncher : IExternalLinkLauncher
{
    public void Open(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch
        {
            // best-effort — see this class's own doc.
        }
    }
}
