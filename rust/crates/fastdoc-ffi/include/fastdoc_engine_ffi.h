// The C ABI for the ported document engine. Mirrors rhwp_native_ffi's ownership rule: every
// char* returned here is freed with fastdoc_string_free, never with free().
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

void fastdoc_string_free(char *s);

#endif
