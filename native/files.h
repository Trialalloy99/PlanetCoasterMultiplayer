/* Dateizugriffe der PC2MP-DLL: kleine Datendateien + Spielstand-Transfer (#14, #3). */
#ifndef PC2MP_FILES_H
#define PC2MP_FILES_H
#include <stddef.h>

#define FILES_MAX_DATA      (16u * 1024u * 1024u)   /* Datendateien in ovldata/PC2MP/data */
#define FILES_SAVE_CHUNK    (512u * 1024u)          /* roh, wie saveChunk in docs/protocol.md */
#define FILES_MAX_SAVE      (256u * 1024u * 1024u)

void   files_init(const char *dll_dir);            /* Verzeichnis der DLL (mit '\') */
void   files_data_dir(char *out, size_t cap);        /* <DLL-Ordner>\data\ (wird angelegt) */
int    files_valid_name(const char *s, size_t n, const char *ext); /* [A-Za-z0-9_.-], 1..96, ext optional */

int    files_write_data(const char *name, size_t nl, const char *data, size_t len, char *err, size_t ecap);
char  *files_read_data(const char *name, size_t nl, size_t *len);   /* malloc; NULL = fehlt */

int    files_saves_dir(char *out, size_t cap);
int    files_find_save(const char *prefix, size_t pl, const char *ext, char *out, size_t cap); /* neueste <prefix>*<ext> */     /* ...\Saved Games\Frontier Developments\Planet Coaster 2\<id>\Saves */
char  *files_save_list_json(size_t *len);          /* [{"name":..,"size":..,"mtime":..}], neueste zuerst; malloc */
char  *files_save_info_json(const char *name, size_t nl, size_t *len);  /* {"name","size","sha256","chunks"} */
char  *files_save_read_chunk_b64(const char *name, size_t nl, long long index, size_t *len);
int    files_save_write_chunk_b64(const char *name, size_t nl, long long index, const char *b64, size_t blen, char *err, size_t ecap);
int    files_save_finish(const char *name, size_t nl, const char *sha_hex, size_t shl, char *err, size_t ecap);
void   files_save_abort(const char *name, size_t nl);

/* intern, auch fuer Tests */
size_t b64_encode(const unsigned char *in, size_t n, char *out);
long long b64_decode(const char *in, size_t n, unsigned char *out);
int    sha256_file_hex(const char *path, char out_hex[65]);
#endif
