using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Avalonia.Platform.Storage;

namespace FastDoc.Avalonia.Open;

/// <summary>
/// The single list of extensions this host offers to open, mirrored from
/// <c>Sources/FastDocReader/App/DocumentTypes.swift</c> (the macOS app's own single source for the
/// same list — its own doc comment there names Info.plist as the mirror it must stay in sync with;
/// this file is now a second one). Kept in one place here too so the open-panel filter, the
/// drag-and-drop filter and the file-association manifest (when this host gets one) all read the
/// same array instead of drifting.
/// </summary>
public static class DocumentExtensions
{
    public static readonly string[] Markdown = { "md", "markdown" };

    public static readonly string[] Office =
    {
        "docx", "docm", "dotx", "dotm", "odt", "hwp", "hwpx",
    };

    public static readonly string[] PlainText =
    {
        "txt", "text", "csv", "tsv", "log", "crash", "ips",
        "conf", "cfg", "ini", "env", "vars", "toml", "cnf",
        "yaml", "yml", "json", "xml", "jsonl", "ndjson",
        "tf", "tfvars", "hcl", "sls", "properties", "lock",
        "graphql", "gql", "proto", "thrift", "avsc",
        "xsd", "wsdl", "dtd", "resx", "strings", "po",
        "har", "http", "rest", "sql", "diff", "patch",
        "mk", "gradle", "cmake", "bzl",
        "rst", "adoc", "asciidoc", "org", "tex", "textile", "nfo",
        "vtt", "srt", "smi", "ass", "ssa", "sub", "lrc",
    };

    /// Every extension this host opens, lower-case, no leading dot.
    public static readonly IReadOnlyList<string> All =
        Markdown.Concat(Office).Concat(PlainText).ToArray();

    public static bool IsSupported(string extension) =>
        All.Contains(extension.TrimStart('.').ToLowerInvariant());
}

/// <summary>
/// Drives the platform file-open dialog (<see cref="IStorageProvider.OpenFilePickerAsync"/>) with a
/// filter built from <see cref="DocumentExtensions"/>, and hands back the chosen local path — or
/// null if the user cancelled or picked something with no local path (e.g. a remote/cloud item the
/// storage provider cannot resolve to a file on disk).
/// </summary>
public static class OpenService
{
    public static async Task<string?> PickFileAsync(IStorageProvider storageProvider)
    {
        var files = await storageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Open a document",
            AllowMultiple = false,
            FileTypeFilter = BuildFileTypeFilter(),
        });
        var file = files.FirstOrDefault();
        return file?.Path.LocalPath;
    }

    private static IReadOnlyList<FilePickerFileType> BuildFileTypeFilter()
    {
        var all = new FilePickerFileType("All supported documents")
        {
            Patterns = DocumentExtensions.All.Select(ext => $"*.{ext}").ToArray(),
        };
        var markdown = new FilePickerFileType("Markdown")
        {
            Patterns = DocumentExtensions.Markdown.Select(ext => $"*.{ext}").ToArray(),
        };
        var office = new FilePickerFileType("Office documents")
        {
            Patterns = DocumentExtensions.Office.Select(ext => $"*.{ext}").ToArray(),
        };
        var plainText = new FilePickerFileType("Plain text")
        {
            Patterns = DocumentExtensions.PlainText.Select(ext => $"*.{ext}").ToArray(),
        };
        return new[] { all, markdown, office, plainText };
    }
}
