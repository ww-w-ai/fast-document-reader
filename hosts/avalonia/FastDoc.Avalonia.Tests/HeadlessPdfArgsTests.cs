using FastDoc.Avalonia.Printing;
using Xunit;

namespace FastDoc.Avalonia.Tests;

/// <summary>`--pdf` argument contract, mirroring macOS HeadlessPDF.parseArgs: `-s/--font-size`
/// 10-36 (default 16, out of range refused), flag accepted anywhere, positional form kept.</summary>
public class HeadlessPdfArgsTests
{
    [Fact]
    public void Positional_form_keeps_working_and_defaults_to_16pt()
    {
        var a = HeadlessPdfArgs.Parse(new[] { "in.md", "out.pdf" });
        Assert.NotNull(a);
        Assert.Equal("in.md", a!.Input);
        Assert.Equal("out.pdf", a.Output);
        Assert.Equal(16, a.FontSizePoints);
        Assert.Equal(1.0, a.Zoom);
    }

    [Theory]
    [InlineData("-s")]
    [InlineData("--font-size")]
    public void Font_size_flag_is_accepted_before_or_after_the_positionals(string flag)
    {
        var before = HeadlessPdfArgs.Parse(new[] { flag, "24", "in.md", "out.pdf" });
        var after = HeadlessPdfArgs.Parse(new[] { "in.md", "out.pdf", flag, "24" });
        Assert.Equal(24, before!.FontSizePoints);
        Assert.Equal(24, after!.FontSizePoints);
        Assert.Equal(1.5, after.Zoom);
    }

    [Fact]
    public void Output_flag_and_default_output_name()
    {
        Assert.Equal("o.pdf", HeadlessPdfArgs.Parse(new[] { "in.md", "-o", "o.pdf" })!.Output);
        Assert.Equal("in.pdf", HeadlessPdfArgs.Parse(new[] { "in.md" })!.Output);
    }

    [Theory]
    [InlineData("9")]
    [InlineData("36.5")]
    [InlineData("abc")]
    [InlineData("NaN")]
    public void Out_of_range_or_malformed_size_is_a_usage_error(string size)
    {
        Assert.Null(HeadlessPdfArgs.Parse(new[] { "in.md", "out.pdf", "-s", size }));
    }

    [Fact]
    public void Bounds_are_inclusive_and_malformed_command_lines_are_refused()
    {
        Assert.Equal(10, HeadlessPdfArgs.Parse(new[] { "a.md", "-s", "10" })!.FontSizePoints);
        Assert.Equal(36, HeadlessPdfArgs.Parse(new[] { "a.md", "-s", "36" })!.FontSizePoints);
        Assert.Null(HeadlessPdfArgs.Parse(new[] { "a.md", "-s" }));
        Assert.Null(HeadlessPdfArgs.Parse(new[] { "-s", "12" }));
        Assert.Null(HeadlessPdfArgs.Parse(new[] { "a.md", "b.pdf", "c" }));
        Assert.Null(HeadlessPdfArgs.Parse(new[] { "a.md", "--bogus" }));
    }
}
