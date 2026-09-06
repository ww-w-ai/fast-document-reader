using System.Text.Json;
using FastDoc.Avalonia.Extract;
using FastDoc.Avalonia.Model;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S7-G: `MarkdownSerializer.Serialize(RenderTree)` against FIXED JSON fixtures — no FFI, no
/// engine dylib, mirroring `RenderTreeEnvelopeTests`'s own style. Each fixture is a hand-built
/// wire tree (the same shape `fastdoc_office_tree_json` would emit) so these tests pin the exact
/// Markdown a given tree shape produces, independent of what any particular real document happens
/// to parse into today.
/// </summary>
public class MarkdownSerializerTests
{
    private static RenderTree Parse(string json) =>
        JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!.Ok!.Value.Deserialize<RenderTree>()!;

    [Fact]
    public void Heading_level_becomes_the_matching_number_of_hashes()
    {
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "heading", "data": { "level": 2, "style": {} } },
              { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "Section Title", "style": {} } }
            ]
          }
        }
        """);

        Assert.Equal("## Section Title", MarkdownSerializer.Serialize(tree));
    }

    [Fact]
    public void Ordered_list_item_keeps_the_documents_own_resolved_marker_literally()
    {
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 3], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "listItem",
                "data": { "level": 0, "ordered": true, "marker": "1.1.2", "style": {} } },
              { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "clause text", "style": {} } },
              { "id": 3, "parentId": 0, "children": [4], "type": "listItem",
                "data": { "level": 0, "ordered": false, "style": {} } },
              { "id": 4, "parentId": 3, "children": [], "type": "textRun", "data": { "text": "bullet text", "style": {} } }
            ]
          }
        }
        """);

        // A real number the reader shows survives extraction (does not get renumbered to "1."),
        // and consecutive list items join with a single newline (OfficeMarkdownSerializer parity).
        Assert.Equal("1.1.2 clause text\n- bullet text", MarkdownSerializer.Serialize(tree));
    }

    [Fact]
    public void Simple_rectangular_table_becomes_a_GFM_pipe_table()
    {
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [10, 20], "type": "table",
                "data": { "gridWidths": [1, 1], "headerRows": 1, "style": {} } },
              { "id": 10, "parentId": 1, "children": [11, 12], "type": "tableRow", "data": { "row": 0, "header": true } },
              { "id": 11, "parentId": 10, "children": [111], "type": "tableCell", "data": { "row": 0, "column": 0 } },
              { "id": 111, "parentId": 11, "children": [1111], "type": "paragraph", "data": { "style": {} } },
              { "id": 1111, "parentId": 111, "children": [], "type": "textRun", "data": { "text": "Name", "style": {} } },
              { "id": 12, "parentId": 10, "children": [121], "type": "tableCell", "data": { "row": 0, "column": 1 } },
              { "id": 121, "parentId": 12, "children": [1211], "type": "paragraph", "data": { "style": {} } },
              { "id": 1211, "parentId": 121, "children": [], "type": "textRun", "data": { "text": "Age", "style": {} } },
              { "id": 20, "parentId": 1, "children": [21, 22], "type": "tableRow", "data": { "row": 1, "header": false } },
              { "id": 21, "parentId": 20, "children": [211], "type": "tableCell", "data": { "row": 1, "column": 0 } },
              { "id": 211, "parentId": 21, "children": [2111], "type": "paragraph", "data": { "style": {} } },
              { "id": 2111, "parentId": 211, "children": [], "type": "textRun", "data": { "text": "Ada", "style": {} } },
              { "id": 22, "parentId": 20, "children": [221], "type": "tableCell", "data": { "row": 1, "column": 1 } },
              { "id": 221, "parentId": 22, "children": [2211], "type": "paragraph", "data": { "style": {} } },
              { "id": 2211, "parentId": 221, "children": [], "type": "textRun", "data": { "text": "36", "style": {} } }
            ]
          }
        }
        """);

        var expected = "| Name | Age |\n| --- | --- |\n| Ada | 36 |";
        Assert.Equal(expected, MarkdownSerializer.Serialize(tree));
    }

    [Fact]
    public void Merged_cell_table_degrades_to_a_raw_block_instead_of_a_fabricated_grid()
    {
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [10], "type": "table",
                "data": { "gridWidths": [1, 1], "headerRows": 0, "style": {} } },
              { "id": 10, "parentId": 1, "children": [11], "type": "tableRow", "data": { "row": 0, "header": false } },
              { "id": 11, "parentId": 10, "children": [111], "type": "tableCell",
                "data": { "row": 0, "column": 0, "columnSpan": 2 } },
              { "id": 111, "parentId": 11, "children": [1111], "type": "paragraph", "data": { "style": {} } },
              { "id": 1111, "parentId": 111, "children": [], "type": "textRun", "data": { "text": "Merged", "style": {} } }
            ]
          }
        }
        """);

        var result = MarkdownSerializer.Serialize(tree);
        Assert.Contains(MarkdownSerializer.RawOpen, result);
        Assert.Contains(MarkdownSerializer.RawNote, result);
        Assert.Contains("Merged", result);
        Assert.Contains(MarkdownSerializer.RawClose, result);
        Assert.DoesNotContain("| --- |", result); // never a fabricated pipe-table delimiter row
    }

    [Fact]
    public void Image_node_uses_the_documents_own_resource_key_and_literal_image_alt_text()
    {
        // OfficeMarkdownSerializer.render's `.image(id, _, _)` case is `("![image](\(id))", false)`
        // -- always the literal word "image" (no alt-text field exists on that OfficeBlock case at
        // all), keyed by `wire::Image.source_key` (a docx media path, or "hwpimg:N"), never the
        // wire's own numeric resourceId. AltText on the wire is real (accessibility use elsewhere)
        // but this rendering path does not read it, matching the macOS oracle byte-for-byte.
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [], "type": "image",
                "data": { "resourceId": 7, "sourceKey": "word/media/image1.png",
                          "intrinsicSize": { "width": 100, "height": 50 }, "altText": "a chart" } }
            ]
          }
        }
        """);

        Assert.Equal("![image](word/media/image1.png)", MarkdownSerializer.Serialize(tree));
    }

    [Fact]
    public void Vector_node_collapses_into_the_same_image_wording_as_a_picture()
    {
        // RenderTreeOfficeAdapter.swift's mapVector ALSO returns `.image(id: key, ...)` -- there is
        // no separate OfficeBlock case for a vector graphic, so it must render identically.
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "hwp", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [], "type": "vector",
                "data": { "sourceKey": "hwpimg:2", "intrinsicSize": { "width": 10, "height": 10 } } }
            ]
          }
        }
        """);

        Assert.Equal("![image](hwpimg:2)", MarkdownSerializer.Serialize(tree));
    }

    [Fact]
    public void Unsupported_graphic_placeholder_uses_only_the_reason_field()
    {
        // RenderTreeOfficeAdapter.swift's `.unsupported(let u): return .unsupportedGraphic(label:
        // u.reason, ...)` reads ONLY `reason` -- neither `sourceFormatTag` nor `preservedText`
        // reaches this OfficeBlock case, so the host must not fall back to either.
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "hwpx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [], "type": "unsupported",
                "data": { "sourceFormatTag": "officeGraphic", "reason": "ole",
                          "preservedText": "should not appear" } }
            ]
          }
        }
        """);

        Assert.Equal("*[ole]*", MarkdownSerializer.Serialize(tree));
    }

    [Fact]
    public void Footnote_reference_becomes_a_markdown_reference_and_the_body_is_appended_at_the_end()
    {
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 5], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2, 3], "type": "paragraph", "data": { "style": {} } },
              { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "See note", "style": {} } },
              { "id": 3, "parentId": 1, "children": [], "type": "textRun",
                "data": { "text": "1)", "style": {}, "footnoteReferenceNumber": 1 } },
              { "id": 5, "parentId": 0, "children": [6], "type": "footnote", "data": { "number": 1, "bodyFlowId": 6 } },
              { "id": 6, "parentId": 5, "children": [7], "type": "flow", "data": {} },
              { "id": 7, "parentId": 6, "children": [8], "type": "paragraph", "data": { "style": {} } },
              { "id": 8, "parentId": 7, "children": [], "type": "textRun", "data": { "text": "The note body.", "style": {} } }
            ]
          }
        }
        """);

        // The marker's own glyph ("1)") is dropped in favour of Markdown's own [^1] syntax, and the
        // footnote node itself never appears inline (it is skipped by the main walk and only
        // reached again, on purpose, to build the trailing definition).
        Assert.Equal("See note[^1]\n\n[^1]: The note body.", MarkdownSerializer.Serialize(tree));
    }

    [Fact]
    public void Bold_italic_and_inline_code_runs_use_their_own_markdown_delimiters()
    {
        // Each word is its own run, with a plain (unstyled) space run between -- a styled run's
        // OWN trailing space would land INSIDE its delimiters (e.g. "**bold **"), which is exactly
        // why FontSubstitutionResolver-style span splits get coalesced back together first for
        // runs that DO share identity; two runs that genuinely differ in style are never merged.
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2, 3, 4, 5, 6], "type": "paragraph", "data": { "style": {} } },
              { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "bold", "style": { "bold": true } } },
              { "id": 3, "parentId": 1, "children": [], "type": "textRun", "data": { "text": " ", "style": {} } },
              { "id": 4, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "italic", "style": { "italic": true } } },
              { "id": 5, "parentId": 1, "children": [], "type": "textRun", "data": { "text": " ", "style": {} } },
              { "id": 6, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "code", "style": { "inlineCode": true } } }
            ]
          }
        }
        """);

        Assert.Equal("**bold** *italic* `code`", MarkdownSerializer.Serialize(tree));
    }

    [Fact]
    public void Missing_root_node_and_missing_document_both_return_an_empty_string_not_a_crash()
    {
        var missingRoot = Parse("""
        { "ok": { "schemaVersion": 1, "document": { "format": "docx", "rootNodeId": 99 }, "nodes": [] } }
        """);
        Assert.Equal("", MarkdownSerializer.Serialize(missingRoot));

        var noDocument = Parse("""
        { "ok": { "schemaVersion": 1, "nodes": [] } }
        """);
        Assert.Equal("", MarkdownSerializer.Serialize(noDocument));
    }
}
