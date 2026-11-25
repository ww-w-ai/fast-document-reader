// The C ABI for the ported document engine. Mirrors rhwp_native_ffi's ownership rule: every
// char* returned here is freed with fastdoc_string_free, never with free().
//
// Ownership (S2B-05), one rule for every function on this page: (1) every returned char* is
// allocated by this library, never by the caller's allocator; (2) an error envelope is owned
// exactly like an ok envelope — a failure is a value, not an exemption from freeing; (3) NULL
// means nothing was allocated, so there is nothing to free (though calling
// fastdoc_string_free(NULL) anyway is safe, see 4); (4) fastdoc_string_free(NULL) is a no-op,
// never undefined behaviour. Freeing a pointer twice, or using one after it is freed, IS
// undefined behaviour and is not a documented failure mode of any function here.
#ifndef FASTDOC_ENGINE_FFI_H
#define FASTDOC_ENGINE_FFI_H

#include <stdbool.h>
#include <stddef.h>

// Reads an office document (docx/docm/dotx/dotm/odt) and returns its Markdown extraction as a
// UTF-8 string, or NULL if it could not be read. Free the result with fastdoc_string_free.
char *fastdoc_extract_markdown(const unsigned char *bytes, size_t len, const char *extension);

// Takes the diagnostic from the most recent failed call on this thread, or NULL. The caller owns
// a non-NULL result and must free it with fastdoc_string_free. Taking clears the diagnostic.
char *fastdoc_take_last_error(void);

// Reads an office document into the canonical RenderTree wire form and returns it as a
// self-describing envelope: {"ffiVersion":1,"ok":<tree JSON>} on success, or
// {"ffiVersion":1,"error":{"kind":...,"message":...,"location":...}} on failure. Unlike
// fastdoc_extract_markdown above, this one does NOT return NULL for a document-level failure —
// the error is inside the returned string. The caller owns the result IN BOTH SHAPES and must
// free it with fastdoc_string_free either way. NULL comes back only when the envelope itself could not be
// built (never on a normal document, read or unreadable).
char *fastdoc_read_office_tree(const unsigned char *bytes, size_t len, const char *extension);

// Reads a TEXT document — markdown or plain text — into the SAME canonical RenderTree envelope
// fastdoc_read_office_tree returns, with the same ownership and the same "the envelope is the
// diagnostic" rule. The producer is chosen by extension: md/markdown parse as markdown, the text
// kinds are read verbatim, and anything else is unsupportedExtension rather than a silent
// fall-through (reading a .docx as text would "succeed" and hand back zip bytes).
char *fastdoc_read_text_tree(const unsigned char *bytes, size_t len, const char *extension);

// Renders a MARKDOWN document to the finished attributed string and returns it on the layer wire,
// in the same envelope shape as the calls above; free with fastdoc_string_free. base_font_size is
// the reader's own size (1...512). A font provider must be installed first.
char *fastdoc_render_markdown(const unsigned char *bytes, size_t len, double base_font_size);

// A markdown render handed over in PIECES, for front-first paint. The handle keeps the builder
// alive between calls, which is what lets block ids keep counting up and each chunk's source
// offsets continue where the last one stopped. Open once, call _next until _is_finished returns 1,
// close exactly once. Same ownership rule as fastdoc_office_open.
typedef struct FastdocMarkdownProgressive FastdocMarkdownProgressive;
FastdocMarkdownProgressive *fastdoc_markdown_progressive_open(const unsigned char *bytes, size_t len,
                                                              double base_font_size);
// The next piece, on the same wire and in the same envelope fastdoc_render_markdown returns;
// free with fastdoc_string_free.
char *fastdoc_markdown_progressive_next(FastdocMarkdownProgressive *handle, size_t blocks);
// 1 finished, 0 not, -1 for a NULL handle.
int fastdoc_markdown_progressive_is_finished(const FastdocMarkdownProgressive *handle);
void fastdoc_markdown_progressive_close(FastdocMarkdownProgressive *handle);

// The document's own default body run size in points, or 11 when it declares none or cannot be
// read. Asked for separately because the read result does not carry it for a zip-backed document.

// Frees a string returned by this library.

/* The font world, answered by the host. Must be installed before any office document is read;
 * reading one without it aborts rather than guessing a font world. A face id of 0 means "no such
 * face", so a host must never issue 0 for a real one. */
typedef struct {
    unsigned long long (*face_named)(const char *name);
    unsigned long long (*resolve)(unsigned long long base, unsigned int traits,
                                  const long long *features, size_t feature_count);
    unsigned long long (*system_face)(double weight, bool monospaced);
    void (*describe)(unsigned long long face, char *name, size_t name_cap,
                     char *family, size_t family_cap, bool *has_family, unsigned int *traits);
    /* CTFontGetGlyphsForCharacters — can this face draw this scalar? */
    bool (*covers)(unsigned long long face, unsigned int scalar);
    /* CTFontCreateForString — what the system substitutes, or 0 for "nothing to offer". */
    unsigned long long (*substitute)(unsigned long long declared, unsigned int scalar);
} FastdocFontProvider;

bool fastdoc_install_font_provider(FastdocFontProvider callbacks);


/* ---------------------------------------------------------------------------------------------
 * The measurement port (S5). The engine decides WHAT belongs in a band and what its height means;
 * the host answers one question — how tall is this text at this width.
 *
 * The payload is BUILT BY RUST, borrowed by the host for the duration of one call, and freed by
 * Rust when the call returns. Copy anything you intend to keep. Every value here is already
 * resolved: the host maps it onto its own text stack one for one and measures. If the host finds
 * itself deciding something, this contract has been broken.
 * ------------------------------------------------------------------------------------------- */

typedef struct { unsigned char alignment; double location; } FastdocTextMeasureTabStop;

typedef struct {
    unsigned char alignment;
    double line_spacing, line_height_multiple, minimum_line_height, maximum_line_height;
    double spacing_before, spacing_after, first_line_head_indent, head_indent, tail_indent;
    const FastdocTextMeasureTabStop *tab_stops;
    size_t tab_stop_count;
} FastdocTextMeasureParagraph;

typedef unsigned char FastdocTextMeasureRunKind; /* 0 = text, 1 = attachment */
#define FastdocTextMeasureRunKindText ((FastdocTextMeasureRunKind)0)
#define FastdocTextMeasureRunKindAttachment ((FastdocTextMeasureRunKind)1)

typedef struct {
    size_t paragraph_index;
    FastdocTextMeasureRunKind kind;
    /* The face's OWN name, not its family: NSFont(name:size:) resolves a face, and a family name
     * silently falls back to the system font wherever the two differ. */
    const char *font_name;
    double size;
    bool bold, italic;
    const char *text;
    /* An attachment's already-fitted box. A run list carrying only fonts and text would drop this
     * contribution and return a number that merely looks like a header height. */
    double attachment_width, attachment_height;
} FastdocTextMeasureRun;

typedef struct {
    const FastdocTextMeasureParagraph *paragraphs;
    size_t paragraph_count;
    const FastdocTextMeasureRun *runs;
    size_t run_count;
} FastdocTextMeasurePayload;

/* One laid-out line (S3): the host's own layout of a payload paragraph, reported so the engine can
 * decide what the document's rules make of it. char_end is a UTF-16 offset within the paragraph's
 * concatenated run text (an attachment counts one unit) of the first position after the line; top
 * is measured from the top of the laid-out column; height is the line's box under the paragraph
 * style the payload carried; baseline is the distance from top to the baseline. */
typedef struct {
    size_t paragraph_index;
    size_t char_end;
    double top, height, baseline;
} FastdocTextMeasureLine;

typedef struct {
    double (*measure)(const FastdocTextMeasurePayload *payload, double width_points);
    /* The same layout, one FastdocTextMeasureLine per line written into out (room for capacity).
     * Returns how many lines the layout HAS; above capacity the engine calls again with room for
     * them all, so a host never truncates silently. NULL when the host has no such primitive. */
    size_t (*measure_lines)(const FastdocTextMeasurePayload *payload, double width_points,
                            FastdocTextMeasureLine *out, size_t capacity);
} FastdocTextMeasureCallbacks;

/* Install once. A second call is ignored rather than swapping, for the same reason the font
 * provider refuses one: two halves of a document measured against different worlds is worse than
 * either world. */
bool fastdoc_install_text_measurer(FastdocTextMeasureCallbacks callbacks);

/* S5C1-01: an opaque handle to a document the engine has already read, so the three sprints after
 * this one (sheet placement, the 바탕쪽, the footnote band) can ask it more than one question
 * without paying the read cost again. Opaque — the host holds only the pointer. */
typedef struct FastdocOfficeDocument FastdocOfficeDocument;

/* Reads an office document ONCE and returns a handle every later query borrows, or NULL on a
 * document this engine cannot read (fastdoc_take_last_error names why — the SAME read_office
 * failure this file's other exports already report). */
FastdocOfficeDocument *fastdoc_office_open(const unsigned char *bytes, size_t len,
                                           const char *extension);

/* Closes a handle fastdoc_office_open returned. NULL is a no-op. Closing a handle twice, or
 * querying one after it is closed, is undefined behaviour — the same statement this file's module
 * doc already makes for a double-freed string, extended to this second owned resource. */
void fastdoc_office_close(FastdocOfficeDocument *handle);

/* U3: the canonical-tree export of a document this handle ALREADY read — fastdoc_read_office_tree
 * without its read. This is a SECOND projection of the same parsed model the handle already holds
 * (never a re-parse). bytes/len are taken because the adapter records the source's sha256 and
 * length from them, not a second copy of the document kept alive in the handle.
 *
 * Returns the SAME self-describing envelope fastdoc_read_office_tree returns
 * ({"ffiVersion":1,"ok":<tree>} or {"ffiVersion":1,"error":{"kind","message","location"}}) —
 * never NULL for a document-level failure, including a NULL handle/bytes, unlike this file's
 * other handle exports. Owned by this library in both shapes and freed with fastdoc_string_free
 * either way; NULL comes back only when the envelope itself could not be built. */
char *fastdoc_office_tree_json(const FastdocOfficeDocument *handle,
                               const unsigned char *bytes, size_t len);

/* One embedded picture's bytes, base64, from the parse this handle still holds. An .hwp is CFB
 * binary, so its pictures are reachable only through the parse that produced the document — which
 * is why the reader used to decode every one of them during the read. `key` is the id the
 * document's own blocks carry ("hwpimg:3"), including a crop variant ("hwpimg:3!crop=..."), whose
 * bytes come back ALREADY CROPPED — the same bytes the read would have embedded under that key,
 * resolved by the same code, so a host can take a picture from here or from the read and draw the
 * same thing. Returns a string the caller frees with fastdoc_string_free, or NULL for
 * a key this document does not have, for a malformed key, and for a document that keeps no parse
 * (docx/odt — their pictures come from the zip the host holds). All three mean "ask elsewhere". */
char *fastdoc_office_image_base64(const FastdocOfficeDocument *handle, const char *key);

/* S5C1-02: the band query re-expressed over an open handle — the engine's own decision for a
 * document's running header, footer AND combined band, in one call, from a document it already
 * holds rather than one it re-reads.
 *
 * The three page values are OPTIONAL in the same sense the host's own page-geometry model treats
 * them: each carries an explicit has_* flag rather than folding "absent" into the value itself, so
 * a value the host actually passed can never be confused with one it did not. headers_on/
 * footers_on mirror the host's own page-view toggles — off is passed through as NO ENTRIES, not a
 * flag the engine reinterprets. separates_pages/desk_gap mirror the host's own page-outline mode:
 * the desk space between two sheets that exists even when neither side draws anything, carried
 * through unchanged rather than dropped, so the flagged build's band matches the host's own for
 * the SAME inputs in outline mode too, not only when a header or footer is present.
 *
 * Fills out[0..3] (header, footer, band) and returns true, or leaves out untouched and returns
 * false — no measurer installed, a band carrying something the engine cannot resolve, or a NULL
 * handle/out pointer — with fastdoc_take_last_error naming which. A refusal is the safe direction:
 * the host falls back to its own answer rather than draw a bandless page. */
bool fastdoc_office_band_sides(const FastdocOfficeDocument *handle, double column_width,
                               double page_content_width, bool has_page_content_width,
                               double page_margin_top, bool has_page_margin_top,
                               double page_margin_bottom, bool has_page_margin_bottom,
                               bool headers_on, bool footers_on, bool separates_pages,
                               double desk_gap, bool has_desk_gap, double *out);

/* S2 of the pagination plan: the PAGE PLAN — where every whole block of a paged document goes,
 * decided once from the heights the host observed. input_json is a PlanInput (page body height,
 * table split preference, optional per-page footnote reservations, and one entry per flow block:
 * an opaque host key — the RenderTree node id on the Avalonia host —, its page flags (section
 * start, hard break, keep-with-next, blank) and what the host measured: line boxes, a picture's
 * height, table row heights). The answer is keyed by the same keys and by block index and carries no
 * text: geometry over node ids, not a second projection of the document.
 *
 * S5 adds, all optional: the footnote band fixpoint run inside the call (notes with their heights,
 * what each block cites, each section's separator; the answer carries the bands and which page
 * cites which note), multi-column runs (column declarations, the body width and the leading band;
 * blocks name their run, the answer carries each line's column), and per-page furniture (the head,
 * foot and master entries the host holds and the sections that veto them; each page of the answer
 * names the entry that applies, its section and the number it prints).
 *
 * Returns {"ffiVersion":1,"ok":<PagePlanV1>} or {"ffiVersion":1,"error":{...}}, owned by this
 * library and freed with fastdoc_string_free — the envelope fastdoc_office_tree_json uses. NULL
 * only when the envelope itself could not be built. handle is never dereferenced — the arithmetic
 * needs no document state — so NULL is allowed for a caller planning heights it measured without
 * holding an open document. */
char *fastdoc_office_page_plan_json(const FastdocOfficeDocument *handle, const char *input_json);

/* S3 of the pagination plan: the LINE MODEL — how tall a paragraph's lines stand and how tall a
 * table row is, from the line boxes the host's own layout produced. input_json is a LineModelInput:
 * the document's line grid, body paragraphs and tables. A paragraph carries each line's natural box,
 * its line-height rule, character size, spacing and whether its format puts the spacing below the
 * glyphs (HWP); a table carries its cells' stacked paragraphs and boxes, paddings and declared
 * heights. The answer is the placed line heights (and the spacing a page may let hang past its
 * foot), each cell's line tops and every row's height. It carries no text and shapes nothing: the
 * host measures, the engine decides what the document's rules make of what was measured.
 *
 * Returns {"ffiVersion":1,"ok":<LineModelOutput>} or {"ffiVersion":1,"error":{...}}, owned by this
 * library and freed with fastdoc_string_free. NULL only when the envelope itself could not be built.
 * The arithmetic needs no document state, so there is no handle. */
char *fastdoc_office_line_model_json(const char *input_json);

/* One cell's own geometry, mirroring the arithmetic in
 * Render/TableBlockBuilder.swift:977-988. */
typedef struct {
    size_t starting_column;
    size_t column_span;
    double pad_left;
    double pad_right;
    double border_left;
    double border_right;
} FastdocTableResizeCell;

/* The arithmetic behind TableBlockBuilder.resizeTables, one call per table — HOST TO RUST,
 * the opposite direction from every other export on this page. Fills out_widths[0..cell_count]
 * with each cells[i]'s target content width and returns true, or leaves out_widths untouched and
 * returns false on a bad payload (fastdoc_take_last_error names which).
 *
 * max_width <= 0.0 means "no authored cap" (a real cap is always a positive point width, so the
 * sentinel cannot collide with an answer).
 *
 * Ownership is inverted from this file's other exports: out_widths is allocated and owned by the
 * CALLER (at least cell_count doubles), lent for the duration of this call only. Nothing here is
 * allocated by this library, so there is no fastdoc_*_free counterpart. */
bool fastdoc_table_resize_cell_widths(const double *column_proportions, size_t column_count,
                                      double available_width, double outer_margin_left,
                                      double outer_margin_right, double max_width,
                                      const FastdocTableResizeCell *cells, size_t cell_count,
                                      double *out_widths);

/* One table's shared-grid inputs plus where its slice sits in the flat column_proportions/cells
 * arrays a batch call shares across every table. */
typedef struct {
    size_t column_offset;
    size_t column_count;
    double available_width;
    double outer_margin_left;
    double outer_margin_right;
    double max_width;
    size_t cell_offset;
    size_t cell_count;
} FastdocTableResizeTableDesc;

/* S5B2b: fastdoc_table_resize_cell_widths above crosses the FFI boundary once PER TABLE, measured
 * at ~15us/table of marshalling. This answers EVERY table in a document in ONE call: tables[i]
 * names its own slice of column_proportions/cells by offset+count, and out_widths is filled in
 * the same flattened table-then-cell order, sized to the SUM of every tables[i].cell_count.
 * Returns false (fastdoc_take_last_error names it) if a descriptor's offset/count runs past its
 * flat buffer, or on a bad payload. Does not replace the single-table export above. */
bool fastdoc_table_resize_cell_widths_batch(const FastdocTableResizeTableDesc *tables,
                                            size_t table_count,
                                            const double *column_proportions,
                                            size_t column_proportions_count,
                                            const FastdocTableResizeCell *cells, size_t cell_count,
                                            double *out_widths);

/* One footnote's own answer: (number, height). An entry struct rather than parallel arrays so
 * the number and height can never come apart. */
typedef struct {
    long long number;
    double height;
} FastdocFootnoteHeightDesc;

/* S5D-2: PageBandGeometry::built_height, called once per footnote this handle's own parse holds,
 * batched into one crossing. Keyed by the document's own number (OfficeFootnote.number), never
 * position. Fills out_entries[0..returned] in the same order this handle's own footnotes are
 * held. Returns the count actually written, or a NEGATIVE value on any refusal
 * (fastdoc_take_last_error names it) -- a NULL handle, an output buffer smaller than the footnote
 * count, or the first note built_height itself could not measure. A refusal is never a partial
 * count -- the whole batch is refused together. */
long long fastdoc_office_footnote_heights(const FastdocOfficeDocument *handle, double column_width,
                                          double page_content_width, bool has_page_content_width,
                                          double document_default_font_size,
                                          FastdocFootnoteHeightDesc *out_entries,
                                          size_t out_capacity);

void fastdoc_string_free(char *s);

#endif
