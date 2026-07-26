#ifndef RHWP_NATIVE_FFI_H
#define RHWP_NATIVE_FFI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

char *rhwp_export_text(const char *input_path, const char *output_dir, int page);
char *rhwp_export_markdown(const char *input_path, const char *output_dir, int page);
char *rhwp_read_text(const char *input_path, int page);
void rhwp_string_free(char *value);

/* Handle-based structured export (parse once, query many, free once).
   Every returned char* must be freed with rhwp_string_free. */
void *rhwp_open(const unsigned char *bytes, size_t len);
char *rhwp_document_json(void *handle);
char *rhwp_image_base64(void *handle, unsigned short bin_data_id);
void rhwp_close(void *handle);

#ifdef __cplusplus
}
#endif

#endif
