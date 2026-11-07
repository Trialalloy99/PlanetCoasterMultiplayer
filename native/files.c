/*
 * Dateizugriffe der PC2MP-DLL.
 *
 * 1. Datendateien (#14): nur in <DLL-Ordner>\data\, Name [A-Za-z0-9_.-] (kein Pfad), max. 16 MB,
 *    atomar geschrieben (temp + MoveFileEx REPLACE_EXISTING|WRITE_THROUGH).
 * 2. Spielstand-Transfer (#3): Saves-Ordner = Saved Games\Frontier Developments\Planet Coaster 2\<SteamID>\Saves.
 *    Lesen chunkweise als base64 (512 KiB roh, wie saveChunk im Protokoll), SHA-256 ueber BCrypt.
 *    Schreiben: Chunks in eine Temp-Datei in data\, nach SHA-256-Pruefung in den Saves-Ordner verschieben.
 *    Bestehende Spielstaende werden NIE ueberschrieben.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>
#include <bcrypt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "files.h"

static char g_dll_dir[MAX_PATH];
static char g_data_dir[MAX_PATH];

void files_init(const char *dll_dir)
{
    snprintf(g_dll_dir, sizeof(g_dll_dir), "%s", dll_dir);
    snprintf(g_data_dir, sizeof(g_data_dir), "%sdata\\", dll_dir);
}

void files_data_dir(char *out, size_t cap)
{
    CreateDirectoryA(g_data_dir, NULL);
    snprintf(out, cap, "%s", g_data_dir);
}

int files_valid_name(const char *s, size_t n, const char *ext)
{
    size_t i, el = ext ? strlen(ext) : 0;
    if (n == 0 || n > 96 || s[0] == '.') return 0;
    for (i = 0; i < n; i++) {
        char c = s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.'))
            return 0;
        if (c == '.' && i + 1 < n && s[i + 1] == '.') return 0;
    }
    if (el && (n <= el || _strnicmp(s + n - el, ext, el) != 0)) return 0;
    return 1;
}

static void set_err(char *err, size_t ecap, const char *msg)
{
    if (err && ecap) snprintf(err, ecap, "%s (Win32 %lu)", msg, GetLastError());
}

static int write_all(const char *path, const char *data, size_t len)
{
    HANDLE h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD w;
    size_t off = 0;
    if (h == INVALID_HANDLE_VALUE) return 0;
    while (off < len) {
        DWORD chunk = (DWORD)((len - off) > (1u << 30) ? (1u << 30) : (len - off));
        if (!WriteFile(h, data + off, chunk, &w, NULL) || w == 0) { CloseHandle(h); return 0; }
        off += w;
    }
    FlushFileBuffers(h);
    CloseHandle(h);
    return 1;
}

static char *read_all(const char *path, size_t maxlen, size_t *len)
{
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    LARGE_INTEGER sz;
    char *buf;
    DWORD r;
    size_t off = 0;
    if (h == INVALID_HANDLE_VALUE) return NULL;
    if (!GetFileSizeEx(h, &sz) || sz.QuadPart < 0 || (unsigned long long)sz.QuadPart > maxlen) { CloseHandle(h); return NULL; }
    buf = (char *)malloc((size_t)sz.QuadPart + 1);
    if (!buf) { CloseHandle(h); return NULL; }
    while (off < (size_t)sz.QuadPart) {
        if (!ReadFile(h, buf + off, (DWORD)((size_t)sz.QuadPart - off), &r, NULL) || r == 0) break;
        off += r;
    }
    CloseHandle(h);
    buf[off] = 0;
    *len = off;
    return buf;
}

int files_write_data(const char *name, size_t nl, const char *data, size_t len, char *err, size_t ecap)
{
    char path[MAX_PATH], tmp[MAX_PATH];
    if (!files_valid_name(name, nl, NULL)) { if (err) snprintf(err, ecap, "ungueltiger Dateiname"); return 0; }
    if (len > FILES_MAX_DATA) { if (err) snprintf(err, ecap, "zu gross (> 16 MB)"); return 0; }
    CreateDirectoryA(g_data_dir, NULL);
    snprintf(path, sizeof(path), "%s%.*s", g_data_dir, (int)nl, name);
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    if (!write_all(tmp, data, len)) { set_err(err, ecap, "Schreiben fehlgeschlagen"); return 0; }
    if (!MoveFileExA(tmp, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        set_err(err, ecap, "Umbenennen fehlgeschlagen");
        DeleteFileA(tmp);
        return 0;
    }
    return 1;
}

char *files_read_data(const char *name, size_t nl, size_t *len)
{
    char path[MAX_PATH];
    if (!files_valid_name(name, nl, NULL)) return NULL;
    snprintf(path, sizeof(path), "%s%.*s", g_data_dir, (int)nl, name);
    return read_all(path, FILES_MAX_DATA, len);
}

/* ------------------------------------------------------------------ base64 / sha256 */

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

size_t b64_encode(const unsigned char *in, size_t n, char *out)
{
    size_t i, o = 0;
    for (i = 0; i + 2 < n; i += 3) {
        unsigned v = (in[i] << 16) | (in[i + 1] << 8) | in[i + 2];
        out[o++] = B64[v >> 18]; out[o++] = B64[(v >> 12) & 63]; out[o++] = B64[(v >> 6) & 63]; out[o++] = B64[v & 63];
    }
    if (i < n) {
        unsigned v = in[i] << 16;
        if (i + 1 < n) v |= in[i + 1] << 8;
        out[o++] = B64[v >> 18]; out[o++] = B64[(v >> 12) & 63];
        out[o++] = (i + 1 < n) ? B64[(v >> 6) & 63] : '=';
        out[o++] = '=';
    }
    out[o] = 0;
    return o;
}

static int b64v(char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

long long b64_decode(const char *in, size_t n, unsigned char *out)
{
    size_t i, o = 0;
    unsigned v = 0;
    int bits = 0;
    for (i = 0; i < n; i++) {
        int d;
        if (in[i] == '=') break;
        if (in[i] == '\r' || in[i] == '\n' || in[i] == ' ') continue;
        d = b64v(in[i]);
        if (d < 0) return -1;
        v = (v << 6) | (unsigned)d; bits += 6;
        if (bits >= 8) { bits -= 8; out[o++] = (unsigned char)((v >> bits) & 0xFF); }
    }
    return (long long)o;
}

int sha256_file_hex(const char *path, char out_hex[65])
{
    BCRYPT_ALG_HANDLE alg = NULL;
    BCRYPT_HASH_HANDLE hh = NULL;
    unsigned char digest[32], *buf;
    HANDLE f;
    DWORD r;
    int ok = 0, i;
    f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    buf = (unsigned char *)malloc(1 << 20);
    if (buf && BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) == 0 &&
        BCryptCreateHash(alg, &hh, NULL, 0, NULL, 0, 0) == 0) {
        ok = 1;
        while (ReadFile(f, buf, 1 << 20, &r, NULL) && r > 0)
            if (BCryptHashData(hh, buf, r, 0) != 0) { ok = 0; break; }
        if (ok && BCryptFinishHash(hh, digest, 32, 0) == 0) {
            for (i = 0; i < 32; i++) snprintf(out_hex + 2 * i, 3, "%02x", digest[i]);
        } else ok = 0;
    }
    if (hh) BCryptDestroyHash(hh);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    free(buf);
    CloseHandle(f);
    return ok;
}

/* ------------------------------------------------------------------ Spielstaende */

int files_saves_dir(char *out, size_t cap)
{
    PWSTR sg = NULL;
    char base[MAX_PATH], pattern[MAX_PATH], best[MAX_PATH] = {0};
    WIN32_FIND_DATAA fd;
    HANDLE hf;
    FILETIME bestt = {0, 0};
#ifdef PC2MP_TEST
    {   /* Tests duerfen nie den echten Saves-Ordner benutzen */
        const char *ov = getenv("PC2MP_TEST_SAVES_DIR");
        if (!ov) return 0;
        snprintf(out, cap, "%s\\", ov);
        return 1;
    }
#endif
    if (SHGetKnownFolderPath(&FOLDERID_SavedGames, 0, NULL, &sg) != S_OK) { CoTaskMemFree(sg); return 0; }
    WideCharToMultiByte(CP_ACP, 0, sg, -1, base, sizeof(base), NULL, NULL);
    CoTaskMemFree(sg);
    strncat(base, "\\Frontier Developments\\Planet Coaster 2\\", sizeof(base) - strlen(base) - 1);
    snprintf(pattern, sizeof(pattern), "%s*", base);
    hf = FindFirstFileA(pattern, &fd);
    if (hf == INVALID_HANDLE_VALUE) return 0;
    do {
        char saves[MAX_PATH];
        WIN32_FILE_ATTRIBUTE_DATA a;
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || fd.cFileName[0] == '.') continue;
        snprintf(saves, sizeof(saves), "%s%s\\Saves", base, fd.cFileName);
        if (!GetFileAttributesExA(saves, GetFileExInfoStandard, &a) || !(a.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
        if (!best[0] || CompareFileTime(&a.ftLastWriteTime, &bestt) > 0) {   /* zuletzt benutztes Profil */
            snprintf(best, sizeof(best), "%s\\", saves);
            bestt = a.ftLastWriteTime;
        }
    } while (FindNextFileA(hf, &fd));
    FindClose(hf);
    if (!best[0]) return 0;
    snprintf(out, cap, "%s", best);
    return 1;
}

typedef struct { char name[MAX_PATH]; unsigned long long size; long long mtime; } save_entry;

static long long ft_to_unix(FILETIME t)
{
    ULARGE_INTEGER u; u.LowPart = t.dwLowDateTime; u.HighPart = t.dwHighDateTime;
    return (long long)(u.QuadPart / 10000000ULL) - 11644473600LL;
}

static int cmp_newest(const void *a, const void *b)
{
    long long d = ((const save_entry *)b)->mtime - ((const save_entry *)a)->mtime;
    return d > 0 ? 1 : (d < 0 ? -1 : 0);
}

char *files_save_list_json(size_t *len)
{
    char dir[MAX_PATH], pattern[MAX_PATH];
    WIN32_FIND_DATAA fd;
    HANDLE hf;
    save_entry *e = NULL;
    int n = 0, cap = 0, i;
    char *out;
    size_t o = 0, ocap;
    if (!files_saves_dir(dir, sizeof(dir))) return NULL;
    snprintf(pattern, sizeof(pattern), "%s*.park2", dir);
    hf = FindFirstFileA(pattern, &fd);
    if (hf != INVALID_HANDLE_VALUE) {
        do {
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
            if (!files_valid_name(fd.cFileName, strlen(fd.cFileName), ".park2")) continue;
            if (n == cap) { cap = cap ? cap * 2 : 32; e = (save_entry *)realloc(e, sizeof(save_entry) * cap); if (!e) { FindClose(hf); return NULL; } }
            snprintf(e[n].name, MAX_PATH, "%s", fd.cFileName);
            e[n].size = ((unsigned long long)fd.nFileSizeHigh << 32) | fd.nFileSizeLow;
            e[n].mtime = ft_to_unix(fd.ftLastWriteTime);
            n++;
        } while (FindNextFileA(hf, &fd));
        FindClose(hf);
    }
    if (n) qsort(e, n, sizeof(save_entry), cmp_newest);
    ocap = 16 + (size_t)n * (MAX_PATH + 64);
    out = (char *)malloc(ocap);
    if (!out) { free(e); return NULL; }
    o += snprintf(out + o, ocap - o, "[");
    for (i = 0; i < n; i++)
        o += snprintf(out + o, ocap - o, "%s{\"name\":\"%s\",\"size\":%llu,\"mtime\":%lld}", i ? "," : "", e[i].name, e[i].size, e[i].mtime);
    o += snprintf(out + o, ocap - o, "]");
    free(e);
    *len = o;
    return out;
}

static int save_path(const char *name, size_t nl, char *out, size_t cap)
{
    char dir[MAX_PATH];
    if (!files_valid_name(name, nl, ".park2") || !files_saves_dir(dir, sizeof(dir))) return 0;
    snprintf(out, cap, "%s%.*s", dir, (int)nl, name);
    return 1;
}

char *files_save_info_json(const char *name, size_t nl, size_t *len)
{
    char path[MAX_PATH], hex[65];
    WIN32_FILE_ATTRIBUTE_DATA a;
    unsigned long long size;
    char *out;
    if (!save_path(name, nl, path, sizeof(path))) return NULL;
    if (!GetFileAttributesExA(path, GetFileExInfoStandard, &a)) return NULL;
    size = ((unsigned long long)a.nFileSizeHigh << 32) | a.nFileSizeLow;
    if (size > FILES_MAX_SAVE || !sha256_file_hex(path, hex)) return NULL;
    out = (char *)malloc(MAX_PATH + 160);
    if (!out) return NULL;
    *len = (size_t)snprintf(out, MAX_PATH + 160, "{\"name\":\"%.*s\",\"size\":%llu,\"sha256\":\"%s\",\"chunks\":%llu,\"chunkSize\":%u}",
                            (int)nl, name, size, hex, (size + FILES_SAVE_CHUNK - 1) / FILES_SAVE_CHUNK, FILES_SAVE_CHUNK);
    return out;
}

char *files_save_read_chunk_b64(const char *name, size_t nl, long long index, size_t *len)
{
    char path[MAX_PATH];
    HANDLE h;
    LARGE_INTEGER pos;
    unsigned char *raw;
    char *out = NULL;
    DWORD r = 0;
    if (index < 0 || !save_path(name, nl, path, sizeof(path))) return NULL;
    h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return NULL;
    pos.QuadPart = index * (long long)FILES_SAVE_CHUNK;
    raw = (unsigned char *)malloc(FILES_SAVE_CHUNK);
    if (raw && SetFilePointerEx(h, pos, NULL, FILE_BEGIN) && ReadFile(h, raw, FILES_SAVE_CHUNK, &r, NULL) && r > 0) {
        out = (char *)malloc(((size_t)r + 2) / 3 * 4 + 1);
        if (out) *len = b64_encode(raw, r, out);
    }
    free(raw);
    CloseHandle(h);
    return out;
}

static void part_path(const char *name, size_t nl, char *out, size_t cap)
{
    snprintf(out, cap, "%sincoming_%.*s.part", g_data_dir, (int)nl, name);
}

int files_save_write_chunk_b64(const char *name, size_t nl, long long index, const char *b64, size_t blen, char *err, size_t ecap)
{
    char path[MAX_PATH];
    unsigned char *raw;
    long long n;
    HANDLE h;
    LARGE_INTEGER pos;
    DWORD w = 0;
    int ok;
    if (!files_valid_name(name, nl, ".park2")) { snprintf(err, ecap, "ungueltiger Spielstand-Name"); return 0; }
    if (index < 0 || index * (long long)FILES_SAVE_CHUNK >= (long long)FILES_MAX_SAVE) { snprintf(err, ecap, "Chunk-Index ausserhalb"); return 0; }
    raw = (unsigned char *)malloc(blen / 4 * 3 + 3);
    if (!raw) { snprintf(err, ecap, "kein Speicher"); return 0; }
    n = b64_decode(b64, blen, raw);
    if (n < 0 || n > (long long)FILES_SAVE_CHUNK) { free(raw); snprintf(err, ecap, "base64 ungueltig"); return 0; }
    CreateDirectoryA(g_data_dir, NULL);
    part_path(name, nl, path, sizeof(path));
    h = CreateFileA(path, GENERIC_WRITE, 0, NULL, index == 0 ? CREATE_ALWAYS : OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) { free(raw); set_err(err, ecap, index == 0 ? "Temp-Datei nicht anlegbar" : "Chunk 0 fehlt"); return 0; }
    pos.QuadPart = index * (long long)FILES_SAVE_CHUNK;
    ok = SetFilePointerEx(h, pos, NULL, FILE_BEGIN) && WriteFile(h, raw, (DWORD)n, &w, NULL) && w == (DWORD)n;
    if (!ok) set_err(err, ecap, "Chunk schreiben fehlgeschlagen");
    CloseHandle(h);
    free(raw);
    return ok;
}

int files_save_finish(const char *name, size_t nl, const char *sha_hex, size_t shl, char *err, size_t ecap)
{
    char part[MAX_PATH], dest[MAX_PATH], hex[65];
    size_t i;
    if (!save_path(name, nl, dest, sizeof(dest))) { snprintf(err, ecap, "ungueltiger Name / Saves-Ordner nicht gefunden"); return 0; }
    part_path(name, nl, part, sizeof(part));
    if (shl != 64 || !sha256_file_hex(part, hex)) { snprintf(err, ecap, "Temp-Datei fehlt oder Hash ungueltig"); return 0; }
    for (i = 0; i < 64; i++) {
        char c = sha_hex[i];
        if (c >= 'A' && c <= 'F') c = (char)(c - 'A' + 'a');
        if (c != hex[i]) { snprintf(err, ecap, "SHA-256 stimmt nicht (Datei beschaedigt)"); DeleteFileA(part); return 0; }
    }
    if (GetFileAttributesA(dest) != INVALID_FILE_ATTRIBUTES) { snprintf(err, ecap, "Spielstand existiert schon (wird nicht ueberschrieben)"); return 0; }
    if (!MoveFileExA(part, dest, MOVEFILE_COPY_ALLOWED | MOVEFILE_WRITE_THROUGH)) { set_err(err, ecap, "Verschieben in Saves fehlgeschlagen"); return 0; }
    return 1;
}

void files_save_abort(const char *name, size_t nl)
{
    char part[MAX_PATH];
    if (!files_valid_name(name, nl, ".park2")) return;
    part_path(name, nl, part, sizeof(part));
    DeleteFileA(part);
}
