using System;
using System.Diagnostics;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// Single instance: Program.cs's real forwarding path (a named Mutex decides which process
/// is primary, a named pipe hands a second launch's document path to it) cannot be exercised by
/// a unit test directly — it needs an actual second OS process and, on the receiving end, a live
/// Avalonia MainWindow. FMD_AVALONIA_PIPE_PROBE proves the TRANSPORT (the exact
/// NamedPipeServerStream/NamedPipeClientStream code the real path uses) with no GUI on either
/// side: "=1" is the server role, "=client" plus a path argument is the client role. This is the
/// same headless proof host-gate.sh's step 4 comment says an automation session needs — no
/// WindowServer connection is available to open a real second window here, but the pipe itself
/// needs none.
///
/// Both roles are driven as real child processes (`dotnet exec &lt;built dll&gt;`), the same way
/// ProgramEntryConventionTests drives --noop and an unknown flag, because Program is internal and
/// Main is a process entry point, not an in-process API.
/// </summary>
public class SingleInstancePipeProbeTests
{
    private static readonly string HostAssemblyPath = typeof(RenderTreeLoader).Assembly.Location;

    [Fact]
    public void Server_receives_exactly_the_path_the_client_sent()
    {
        const string forwardedPath = "/tmp/fastdoc-pipe-probe-test-document.md";

        using var server = StartHost(env: "1");
        try
        {
            // The client only needs to win the race to connect after the server's pipe is
            // listening, not after the server process has fully booted the .NET runtime — a
            // fixed pre-connect sleep is the simplest wait that is still generous next to the
            // server's own 5s WaitForConnectionAsync timeout (Program.RunPipeProbeServer).
            System.Threading.Thread.Sleep(500);

            var (clientExitCode, clientStdout, clientStderr) = RunHost(env: "client", forwardedPath);

            Assert.Equal(0, clientExitCode);
            Assert.Contains($"sent-path: {forwardedPath}", clientStdout);
            Assert.Contains("mode: headless --pipe-probe", clientStderr);

            var serverStdout = server.StandardOutput.ReadToEnd();
            var serverStderr = server.StandardError.ReadToEnd();
            var serverExited = server.WaitForExit(TimeSpan.FromSeconds(10));
            if (!serverExited)
            {
                server.Kill(entireProcessTree: true);
                throw new TimeoutException("pipe-probe server did not exit within 10s of the client sending");
            }

            Assert.Equal(0, server.ExitCode);
            Assert.Contains("mode: headless --pipe-probe", serverStderr);
            Assert.Contains($"received-path: {forwardedPath}", serverStderr);
            Assert.Empty(serverStdout); // the server's payload line is on stderr, per the spec above
        }
        finally
        {
            if (!server.HasExited)
            {
                server.Kill(entireProcessTree: true);
            }
        }
    }

    [Fact]
    public void Server_times_out_and_exits_nonzero_when_no_client_ever_connects()
    {
        // No forwarding launch happens here at all: this proves the server does not hang forever
        // when a primary instance's pipe server starts but a racing client dies before connecting.
        var (exitCode, _, stderr) = RunHost(env: "1");

        Assert.Equal(1, exitCode);
        Assert.Contains("timed out waiting for a connection", stderr);
    }

    private static (int ExitCode, string Stdout, string Stderr) RunHost(string env, params string[] args)
    {
        using var process = StartHost(env, args);
        var stdout = process.StandardOutput.ReadToEnd();
        var stderr = process.StandardError.ReadToEnd();
        var exited = process.WaitForExit(TimeSpan.FromSeconds(30));
        if (!exited)
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException($"dotnet exec {HostAssemblyPath} (FMD_AVALONIA_PIPE_PROBE={env}) did not exit within 30s");
        }
        return (process.ExitCode, stdout, stderr);
    }

    private static Process StartHost(string env, params string[] args)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "dotnet",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add("exec");
        startInfo.ArgumentList.Add(HostAssemblyPath);
        foreach (var arg in args)
        {
            startInfo.ArgumentList.Add(arg);
        }
        startInfo.Environment["FMD_AVALONIA_PIPE_PROBE"] = env;

        return Process.Start(startInfo)
            ?? throw new InvalidOperationException($"failed to start dotnet exec {HostAssemblyPath}");
    }
}
