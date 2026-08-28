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

// Reads an office document and returns the JSON envelope a host decodes, or NULL. NULL also means
// "read, but cannot be handed over intact" — the host should use its own reader. Free with
// fastdoc_string_free.
char *fastdoc_read_office_json(const unsigned char *bytes, size_t len, const char *extension);

// Takes the diagnostic from the most recent failed call on this thread, or NULL. The caller owns
// a non-NULL result and must free it with fastdoc_string_free. Taking clears the diagnostic.
char *fastdoc_take_last_error(void);

// Reads an office document into the canonical RenderTree wire form and returns it as a
// self-describing envelope: {"ffiVersion":1,"ok":<tree JSON>} on success, or
// {"ffiVersion":1,"error":{"kind":...,"message":...,"location":...}} on failure. Unlike the two
// exports above, this one does NOT return NULL for a document-level failure — the error is inside
// the returned string. The caller owns the result IN BOTH SHAPES and must free it with
// fastdoc_string_free either way. NULL comes back only when the envelope itself could not be
// built (never on a normal document, read or unreadable).
char *fastdoc_read_office_tree(const unsigned char *bytes, size_t len, const char *extension);

// The document's own default body run size in points, or 11 when it declares none or cannot be
// read. Asked for separately because the read result does not carry it for a zip-backed document.
double fastdoc_office_default_body_font_size(const unsigned char *bytes, size_t len, const char *extension);

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

typedef struct {
    double (*measure)(const FastdocTextMeasurePayload *payload, double width_points);
} FastdocTextMeasureCallbacks;

/* Install once. A second call is ignored rather than swapping, for the same reason the font
 * provider refuses one: two halves of a document measured against different worlds is worse than
 * either world. */
bool fastdoc_install_text_measurer(FastdocTextMeasureCallbacks callbacks);

/* The running header (or footer) band height for a document, decided in the engine and measured
 * through the port above. Returns a negative value when it cannot answer — no measurer installed,
 * the document unreadable, or the band carrying something whose size the engine does not know —
 * and `fastdoc_take_last_error` names which. A height is never negative, so the sentinel cannot
 * collide with an answer. */
double fastdoc_office_header_band_height(const unsigned char *bytes, size_t len,
                                         const char *extension, double column_width,
                                         bool footer);

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

/* The schema-v4 export of a document this handle ALREADY read — fastdoc_read_office_json without
 * its read. The app used to read every office document twice (once for its content, once to open
 * the handle); this is the call that makes the second read unnecessary. bytes/len are the
 * document's own source bytes, which the caller already holds — they are taken rather than stored
 * so the handle does not keep a second copy of the document alive. Returns a JSON string the
 * caller frees with fastdoc_string_free, or NULL on failure (fastdoc_take_last_error names why).
 * The bytes are indistinguishable from fastdoc_read_office_json's, deliberately. */
char *fastdoc_office_content_json(const FastdocOfficeDocument *handle,
                                  const unsigned char *bytes, size_t len);

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

/* S5C2-01: every SHEET a paged document prints as, from the scalars printSheets already resolves
 * (pitch and top_margin are scalar addition/max and are NOT crossed separately — S5C-2's own plan
 * says why). count is the host's own live printPageCount.
 *
 * Fills out[0..count*4] as [x, y, width, height] per sheet, in the same order the host's own
 * PagePagination.sheets returns them, and sets *out_count to the number written. Returns false
 * (fastdoc_take_last_error names it) when out_capacity is smaller than count * 4, or on a NULL
 * handle/out/out_count.
 *
 * handle is unused beyond the NULL check — this arithmetic needs no document state — but the
 * export is shaped over the handle for consistency with this file's other S5C1/S5C2 exports. */
bool fastdoc_office_sheets(const FastdocOfficeDocument *handle, long long count, double width,
                           double text_origin_y, double leading_band, double pitch,
                           double top_margin, double desk_gap, double *out, size_t out_capacity,
                           size_t *out_count);

/* One laid-out ROW, mirroring page_pagination::LaidOutRow field for field —
 * fastdoc_office_table_placement's flat rows array, sliced per table by row_offset/row_count. */
typedef struct {
    long long first_char;
    double top;
    double bottom;
    double first_line_top;
    bool can_break_above;
} FastdocLaidOutRow;

/* One laid-out TABLE, mirroring page_pagination::LaidOutTable except that rows is replaced by an
 * offset/count into fastdoc_office_table_placement's flat rows array — the same shape
 * FastdocTableResizeTableDesc already uses for tables-then-cells. */
typedef struct {
    long long first_char;
    double visual_top;
    double bottom;
    double first_line_top;
    long long last_char;
    size_t row_offset;
    size_t row_count;
    bool keeps_whole;
} FastdocLaidOutTable;

/* One first_char -> (height, top_inset) entry — the wire shape both already_pushed's input and
 * tables_to_push's output use. */
typedef struct {
    long long key;
    double height;
    double top_inset;
} FastdocTableMetricsEntry;

/* One page -> height entry — note_bands's wire shape. The host may pass these in any order: the
 * engine builds a HashMap from them and neither tables_to_push nor oversized_pieces reads that
 * map in iteration order, only by key lookup. */
typedef struct {
    long long page;
    double value;
} FastdocNoteBandEntry;

/* One first_char -> last_char entry — already_oversized's wire shape (input) and
 * oversized_pieces's wire shape (output). */
typedef struct {
    long long key;
    long long value;
} FastdocI64Entry;

/* S5C2-01: which tables must move whole to the next page (tables_to_push) and which pieces fit on
 * no page at all (oversized_pieces), from a completed layout — settlePagedTables's arithmetic
 * half, over the S5C-1 handle for consistency (unused beyond the NULL check; both Rust functions
 * are pure).
 *
 * joining_unopened_boundaries is NOT answered here — it has exactly one caller, pageSheets, which
 * S5C-2's own contract leaves deriving from printSheets untouched.
 *
 * tables/rows are the host's laidOutTables() walk, flattened: each table names its own slice of
 * rows by row_offset/row_count. already_pushed/note_bands/already_oversized are the settle loop's
 * carried state, each a flat array of entries in any order.
 *
 * Fills out_push/out_oversized — each SORTED BY KEY, so two runs over the same document answer
 * identically regardless of Rust's own randomized HashMap iteration order — and sets
 * *out_push_count/*out_oversized_count to the number of entries written. Returns false
 * (fastdoc_take_last_error names it) when either output buffer is too small, when a table
 * descriptor's row_offset/row_count runs past the flat rows buffer, or on a NULL handle/required
 * pointer. A safe upper bound for both output capacities is table_count + row_count. */
bool fastdoc_office_table_placement(
    const FastdocOfficeDocument *handle, const FastdocLaidOutTable *tables, size_t table_count,
    const FastdocLaidOutRow *rows, size_t row_count, double page_content_height, double band,
    double leading_band, bool split_tables, const FastdocTableMetricsEntry *already_pushed,
    size_t already_pushed_count, const FastdocNoteBandEntry *note_bands, size_t note_bands_count,
    const FastdocI64Entry *already_oversized, size_t already_oversized_count,
    FastdocTableMetricsEntry *out_push, size_t out_push_capacity, size_t *out_push_count,
    FastdocI64Entry *out_oversized, size_t out_oversized_capacity, size_t *out_oversized_count);

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

/* One master-page TEMPLATE descriptor, (section, appliesTo) mirroring OfficeMasterPage's own two
 * selection fields. applies_to is HeaderFooterApplicability's wire tag: 0 = defaultPages,
 * 1 = firstPage, 2 = evenPages. */
typedef struct {
    long long section;
    int applies_to;
} FastdocMasterTemplateDesc;

/* One VISIBLE page's selection query, (pageIndex, section?) mirroring
 * MasterPagePainter.applicablePage's own two arguments beyond the template list.
 * has_section == false matches applicablePage's own nil fallback: every template is a candidate,
 * not none. */
typedef struct {
    long long page_index;
    bool has_section;
    long long section;
} FastdocMasterPageQuery;

/* S5C3-01/03: MasterPagePainter.applicablePage plus the section veto (:73), ported as a pure
 * function and batched over every visible page in ONE call per draw pass. out_template_index[i]
 * is the applicable template's index into the caller's own templates array for pages[i], or -1
 * for "no template applies" (no candidates for the page's section, or the page's section is
 * vetoed). */
bool fastdoc_office_master_selection(const FastdocMasterTemplateDesc *templates,
                                     size_t template_count,
                                     const long long *vetoed_sections,
                                     size_t vetoed_section_count,
                                     const FastdocMasterPageQuery *pages, size_t page_count,
                                     long long *out_template_index, size_t out_capacity);

/* One page's footnote inputs to the settle round: its own cited notes' heights (a slice into
 * the shared note_heights buffer via note_offset/note_count) and its own section's resolved
 * separator. has_separator == false is footnoteSeparator(forPage:)'s own nil — no separator for
 * this page's section at all, distinct from separator_is_declared == false (a separator struct
 * the document never populated). */
typedef struct {
    long long page_index;
    size_t note_offset;
    size_t note_count;
    bool has_separator;
    bool separator_is_declared;
    long long separator_line_type;
    double separator_line_width_pt;
    double separator_margin_top_pt;
    double separator_margin_bottom_pt;
    double separator_note_spacing_pt;
} FastdocFootnotePageDesc;

/* One earlier round's proposal, its own slice into the flat history_entries buffer (the settle's
 * own carried history, oldest round first). */
typedef struct {
    size_t entry_offset;
    size_t entry_count;
} FastdocFootnoteHistoryRoundDesc;

/* S5D1-02: FootnoteBandSettle.step (invariant 98) plus the proposal arithmetic that feeds it
 * (footnote_band_height/separator_allowance), batched into one round-trip per settle round. The
 * host still supplies the note heights and resolves page-to-section/the separator for each page;
 * the engine answers only what to do with the round that just finished.
 *
 * out_bands[0..*out_count], sorted by page, is the settle's bands for this round. *out_outcome
 * names which kind of answer it is (0 = retry, run again with these bands; 1 = stop, these bands
 * are final) and *out_stop_reason names why a stop happened (0 = still, 1 = cycle, 2 = cap;
 * meaningless, left at -1, when *out_outcome is retry). Returns false
 * (fastdoc_take_last_error names it) on a NULL required argument, an offset/count that runs past
 * its flat buffer, or an output buffer smaller than the answer needs. A safe upper bound for
 * out_capacity is page_count. */
bool fastdoc_office_footnote_band_settle(const FastdocFootnotePageDesc *pages, size_t page_count,
                                         const double *note_heights, size_t note_heights_count,
                                         const FastdocFootnoteHistoryRoundDesc *history_rounds,
                                         size_t history_round_count,
                                         const FastdocNoteBandEntry *history_entries,
                                         size_t history_entry_count,
                                         double page_content_height, long long cap,
                                         FastdocNoteBandEntry *out_bands, size_t out_capacity,
                                         size_t *out_count, int *out_outcome, int *out_stop_reason);

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
