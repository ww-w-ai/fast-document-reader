// The C ABI for the ported document engine. Mirrors rhwp_native_ffi's ownership rule: every
// char* returned here is freed with fastdoc_string_free, never with free().
#ifndef FASTDOC_ENGINE_FFI_H
#define FASTDOC_ENGINE_FFI_H

#include <stddef.h>

// Reads an office document (docx/docm/dotx/dotm/odt) and returns its Markdown extraction as a
// UTF-8 string, or NULL if it could not be read. Free the result with fastdoc_string_free.
char *fastdoc_extract_markdown(const unsigned char *bytes, size_t len, const char *extension);

// Reads an office document and returns the JSON envelope a host decodes, or NULL. NULL also means
// "read, but cannot be handed over intact" — the host should use its own reader. Free with
// fastdoc_string_free.
char *fastdoc_read_office_json(const unsigned char *bytes, size_t len, const char *extension);

// Frees a string returned by this library.
void fastdoc_string_free(char *s);

#endif
