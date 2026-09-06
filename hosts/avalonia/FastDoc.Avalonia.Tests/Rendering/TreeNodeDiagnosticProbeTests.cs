using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;
using Xunit;

namespace FastDoc.Avalonia.Tests.Rendering;

/// <summary>S8-A2 diagnostic probe — not a regression test. Dumps a real document's "unsupported"
/// and "header"/"footer" nodes (type/data/parent chain) to stderr so a defect's exact wire shape
/// can be read instead of guessed at. Gated by FMD_DUMP_TREE_PATH (a document path) plus
/// FMD_DUMP_TREE_TYPE (a node "type" to filter on, e.g. "unsupported"/"header"/"footer") — silently
/// skips when either is unset, same convention as this repo's other FMD_* corpus probes.</summary>
public class TreeNodeDiagnosticProbeTests
{
    [Fact]
    public void DumpNodesOfType()
    {
        var path = Environment.GetEnvironmentVariable("FMD_DUMP_TREE_PATH");
        var nodeType = Environment.GetEnvironmentVariable("FMD_DUMP_TREE_TYPE");
        if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(nodeType))
        {
            return; // probe not requested
        }

        var loaded = RenderTreeLoader.Load(path);
        using var handle = loaded.Handle;
        Assert.True(loaded.IsOk, loaded.Error?.Message);
        var tree = loaded.Tree!;

        var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
        var parentOf = new Dictionary<ulong, ulong>();
        foreach (var node in tree.Nodes)
        {
            byId[node.Id] = node;
        }
        foreach (var node in tree.Nodes)
        {
            foreach (var childId in node.Children)
            {
                parentOf[childId] = node.Id;
            }
        }

        // How many times does each node id appear as a CHILD across the whole tree — >1 means a
        // DAG shape (one node reachable from two parents), which a naive recursive walker visits
        // twice.
        var childOccurrences = new Dictionary<ulong, int>();
        foreach (var node in tree.Nodes)
        {
            foreach (var childId in node.Children)
            {
                childOccurrences[childId] = childOccurrences.GetValueOrDefault(childId) + 1;
            }
        }

        var matches = tree.Nodes.Where(n => n.Type == nodeType).ToList();
        var outLines = new List<string> { $"treeprobe: type={nodeType} matches={matches.Count} totalNodes={tree.Nodes.Count}" };
        foreach (var node in matches)
        {
            var occurrences = childOccurrences.GetValueOrDefault(node.Id);
            var chain = new List<string>();
            var cursor = node.Id;
            var guard = 0;
            while (parentOf.TryGetValue(cursor, out var parent) && guard++ < 20)
            {
                if (byId.TryGetValue(parent, out var parentNode))
                {
                    chain.Add($"{parentNode.Type}#{parent}");
                }
                cursor = parent;
            }
            outLines.Add(
                $"  id={node.Id} childOccurrences={occurrences} ancestry={string.Join("<-", chain)} data={node.Data.GetRawText()}");
        }

        var outPath = Environment.GetEnvironmentVariable("FMD_DUMP_TREE_OUT");
        if (!string.IsNullOrEmpty(outPath))
        {
            System.IO.File.WriteAllLines(outPath, outLines);
        }
        foreach (var line in outLines) { Console.Error.WriteLine(line); }
    }

    /// <summary>S8-A2 (C4) probe: scans every "textRun" node's text for a control code point
    /// (< U+0020, excluding none — a real newline never reaches a textRun's own text; that is
    /// always a separate "lineBreak" node) and dumps the run plus its nearest ancestor so the
    /// EXACT code point behind a tofu glyph can be read instead of guessed at. Gated by
    /// FMD_DUMP_CONTROL_CHARS_PATH; silently skips when unset.</summary>
    [Fact]
    public void DumpControlCharacterRuns()
    {
        var path = Environment.GetEnvironmentVariable("FMD_DUMP_CONTROL_CHARS_PATH");
        if (string.IsNullOrEmpty(path)) { return; }

        var loaded = RenderTreeLoader.Load(path);
        using var handle = loaded.Handle;
        Assert.True(loaded.IsOk, loaded.Error?.Message);
        var tree = loaded.Tree!;

        var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
        var parentOf = new Dictionary<ulong, ulong>();
        foreach (var node in tree.Nodes) { byId[node.Id] = node; }
        foreach (var node in tree.Nodes)
        {
            foreach (var childId in node.Children) { parentOf[childId] = node.Id; }
        }

        var outLines = new List<string>();
        foreach (var node in tree.Nodes)
        {
            if (node.Type != "textRun") { continue; }
            var tr = node.AsTextRun;
            if (tr is null) { continue; }
            var controlChars = tr.Text.Where(c => c < 0x20 || (c >= 0x2000 && c <= 0x206F && char.IsControl(c) == false && (c == '․' || c == '‥' || c == '…'))).Distinct().ToList();
            var hasControl = tr.Text.Any(c => c < 0x20);
            if (!hasControl) { continue; }
            var codepoints = string.Join(",", tr.Text.Where(c => c < 0x20).Distinct().Select(c => $"U+{(int)c:X4}"));
            var ancestryParent = parentOf.TryGetValue(node.Id, out var p) && byId.TryGetValue(p, out var pn) ? pn.Type : "?";
            var visible = new string(tr.Text.Select(c => c < 0x20 ? '␦' : c).ToArray());
            outLines.Add($"id={node.Id} parent={ancestryParent} codepoints=[{codepoints}] text=\"{visible}\"");
        }

        var outPath = Environment.GetEnvironmentVariable("FMD_DUMP_CONTROL_CHARS_OUT");
        if (!string.IsNullOrEmpty(outPath))
        {
            System.IO.File.WriteAllLines(outPath, outLines.Count > 0 ? outLines : new List<string> { "(none found)" });
        }
        foreach (var line in outLines) { Console.Error.WriteLine(line); }
    }

    /// <summary>S8-A2 (C4) probe, HWP variant: a HWP table-of-contents tab-leader carries NO
    /// embedded control character in its "textRun" text at all (confirmed against this test's own
    /// corpus — see the report), so the tofu glyph reported at that spot must come from a real
    /// PRINTED character Inter has no glyph for, not a control code point. Dumps every distinct
    /// character above U+2000 (leader/dash/space blocks) any textRun in the document actually
    /// carries, with a paragraph excerpt, so the exact character can be identified. Gated by
    /// FMD_DUMP_HIGH_CHARS_PATH.</summary>
    [Fact]
    public void DumpHighUnicodeCharacterUsage()
    {
        var path = Environment.GetEnvironmentVariable("FMD_DUMP_HIGH_CHARS_PATH");
        if (string.IsNullOrEmpty(path)) { return; }

        var loaded = RenderTreeLoader.Load(path);
        using var handle = loaded.Handle;
        Assert.True(loaded.IsOk, loaded.Error?.Message);
        var tree = loaded.Tree!;

        var byChar = new Dictionary<char, List<string>>();
        foreach (var node in tree.Nodes)
        {
            if (node.Type != "textRun") { continue; }
            var tr = node.AsTextRun;
            if (tr is null) { continue; }
            foreach (var c in tr.Text)
            {
                if (c < 0x2000 || c > 0x2BFF) { continue; } // general punctuation..misc symbols/arrows
                if (!byChar.TryGetValue(c, out var examples))
                {
                    examples = new List<string>();
                    byChar[c] = examples;
                }
                if (examples.Count < 3) { examples.Add(tr.Text); }
            }
        }

        var outLines = byChar.OrderBy(kv => (int)kv.Key)
            .Select(kv => $"U+{(int)kv.Key:X4} '{kv.Key}' count-examples={kv.Value.Count} examples={string.Join(" | ", kv.Value)}")
            .ToList();

        var outPath = Environment.GetEnvironmentVariable("FMD_DUMP_HIGH_CHARS_OUT");
        if (!string.IsNullOrEmpty(outPath))
        {
            System.IO.File.WriteAllLines(outPath, outLines.Count > 0 ? outLines : new List<string> { "(none found)" });
        }
        foreach (var line in outLines) { Console.Error.WriteLine(line); }
    }
}
