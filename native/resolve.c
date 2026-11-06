/*
 * Findet interne Lua-Funktionen der Spiel-Exe zur Laufzeit per Byte-Signatur.
 *
 * Statisch verifiziert (PlanetCoaster2.exe, Stand 2026-11-06, Funde jeweils eindeutig):
 *   luaS_newlstr  RVA 0x1e48bf0   Prolog + "cmp r8, 0x28" (LUAI_MAXSHORTLEN 40)
 *   luaS_new      RVA 0x1e48cb0   "mov eax, 0x3521CFB3; mul edx" (= Adresse % 53, String-Cache)
 *                                 ruft am Ende luaS_newlstr(L, str, strlen(str)) -> Gegenprobe
 *   Stack-Stempel RVA 0x33856e8  "mov eax,[g]; inc eax; mov [g],eax" (1307 Stellen, gleiche Adresse)
 * Alles liegt im unverschluesselten Bereich der Exe (Section ".arch"); nur gelesen, nie gepatcht.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "frontier_lua.h"

typedef struct { const unsigned char *b; const char *m; size_t n; } sig;

/* "48 89 ?? 24" -> Bytes + Maske ('x' = muss passen, '?' = egal) */
static size_t parse_sig(const char *txt, unsigned char *bytes, char *mask, size_t cap)
{
    size_t n = 0;
    while (*txt && n < cap) {
        while (*txt == ' ') txt++;
        if (!*txt) break;
        if (txt[0] == '?') { bytes[n] = 0; mask[n] = '?'; txt += (txt[1] == '?') ? 2 : 1; }
        else { unsigned v; sscanf(txt, "%2x", &v); bytes[n] = (unsigned char)v; mask[n] = 'x'; txt += 2; }
        n++;
    }
    return n;
}

typedef struct { const unsigned char *start; size_t size; } region;

/* Ausfuehrbare Sections des Images; bei live=1 nur committete, lesbare Seiten. */
static int exec_regions(const unsigned char *base, int live, region *out, int cap)
{
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    const IMAGE_NT_HEADERS64 *nt;
    const IMAGE_SECTION_HEADER *sec;
    int i, n = 0;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    nt = (const IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;
    sec = IMAGE_FIRST_SECTION(nt);
    for (i = 0; i < nt->FileHeader.NumberOfSections; i++) {
        const unsigned char *p = base + sec[i].VirtualAddress;
        size_t sz = sec[i].Misc.VirtualSize;
        if (!(sec[i].Characteristics & IMAGE_SCN_MEM_EXECUTE) || sz == 0) continue;
        if (!live) {
            if (n < cap) { out[n].start = p; out[n].size = sz; n++; }
            continue;
        }
        /* In zusammenhaengende lesbare Bereiche zerlegen */
        while (sz > 0) {
            MEMORY_BASIC_INFORMATION mbi;
            size_t chunk;
            if (!VirtualQuery(p, &mbi, sizeof(mbi))) break;
            chunk = (size_t)((const unsigned char *)mbi.BaseAddress + mbi.RegionSize - p);
            if (chunk > sz) chunk = sz;
            if (mbi.State == MEM_COMMIT && !(mbi.Protect & (PAGE_GUARD | PAGE_NOACCESS)) &&
                (mbi.Protect & (PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_READONLY | PAGE_READWRITE |
                                PAGE_EXECUTE_WRITECOPY | PAGE_WRITECOPY))) {
                if (n < cap) { out[n].start = p; out[n].size = chunk; n++; }
            }
            p += chunk; sz -= chunk;
        }
    }
    return n;
}

/* Sucht ein Muster; liefert Anzahl Treffer (max. 2 werden gemerkt) */
static int find_sig(region *rg, int nrg, const char *txt, const unsigned char **hit)
{
    unsigned char b[128]; char m[128];
    size_t n = parse_sig(txt, b, m, sizeof(b)), k;
    int r, count = 0;
    *hit = NULL;
    for (r = 0; r < nrg; r++) {
        const unsigned char *p = rg[r].start, *end = rg[r].start + rg[r].size;
        if (rg[r].size < n) continue;
        end -= n;
        for (; p <= end; p++) {
            p = (const unsigned char *)memchr(p, b[0], (size_t)(end - p) + 1);
            if (!p) break;
            for (k = 1; k < n; k++) if (m[k] == 'x' && p[k] != b[k]) break;
            if (k == n) { if (!*hit) *hit = p; count++; if (count > 1) return count; }
        }
    }
    return count;
}

static const char *SIG_NEWLSTR =
    "48 89 6C 24 ?? 41 56 48 83 EC 20 49 8B E8 4C 8B F2 49 83 F8 28 77 ?? 48 8B 6C 24 ?? 48 83 C4 20 41 5E E9";
/* Mitte von luaS_new: mov r10,rdx; mov eax,0x3521CFB3; mul edx */
static const char *SIG_NEWSTR_MID = "4C 8B D2 B8 B3 CF 21 35 F7 E2";

/* In luaS_new: nach der strlen-Schleife "mov rdx, r10; mov rcx, rdi; call luaS_newlstr" */
static const unsigned char *call_target_in_newstr(const unsigned char *mid)
{
    const unsigned char *p;
    for (p = mid; p < mid + 0xA0; p++) {
        if (p[0] == 0x49 && p[1] == 0x8B && p[2] == 0xD2 && p[6] == 0xE8) {
            int rel; memcpy(&rel, p + 7, 4);
            return p + 11 + rel;
        }
    }
    return NULL;
}

int flua_resolve_image(const unsigned char *base, flua_resolved *out)
{
    region rg[512];
    int nrg, cnt, cnt2;
    const unsigned char *newlstr = NULL, *mid = NULL, *viacall = NULL;
    memset(out, 0, sizeof(*out));
    nrg = exec_regions(base, base == (const unsigned char *)GetModuleHandleW(NULL), rg, 512);
    if (nrg == 0) { snprintf(out->info, sizeof(out->info), "kein PE-Image / keine Code-Sections"); return 0; }

    /* Schneller Weg: Region fuer Region; sobald beide Signaturen in derselben Region liegen und
       luaS_new -> call -> luaS_newlstr passt, ist das Ergebnis eindeutig belegt (spart ~1 s Page-ins). */
    cnt = cnt2 = 0;
    {
        int r;
        for (r = 0; r < nrg; r++) {
            const unsigned char *h1 = NULL, *h2 = NULL;
            int c1 = find_sig(&rg[r], 1, SIG_NEWLSTR, &h1);
            int c2 = find_sig(&rg[r], 1, SIG_NEWSTR_MID, &h2);
            if (c1 == 1 && c2 == 1 && call_target_in_newstr(h2) == h1) {
                newlstr = h1; mid = h2; viacall = h1; cnt = cnt2 = 1;
                break;
            }
        }
    }
    if (!viacall) {
        /* Voller Scan (Muster evtl. durch Update verschoben) */
        cnt = find_sig(rg, nrg, SIG_NEWLSTR, &newlstr);
        cnt2 = find_sig(rg, nrg, SIG_NEWSTR_MID, &mid);
        if (cnt2 == 1) viacall = call_target_in_newstr(mid);
    }
    if (cnt == 1 && (!viacall || viacall == newlstr)) {
        out->newlstr = (luaS_newlstr_fn)newlstr;
    } else if (cnt != 1 && viacall) {
        /* Signatur gebrochen (Update), aber Aufruf aus luaS_new gefunden */
        out->newlstr = (luaS_newlstr_fn)viacall;
    }
    if (out->newlstr) out->newlstr_rva = (unsigned long long)((const unsigned char *)out->newlstr - base);
    if (mid) out->newstr_rva = (unsigned long long)(mid - 10 - base);

    /* Stack-Stempel: haeufigstes Ziel von "mov eax,[rip+a]; inc eax; mov [rip+a],eax; mov [reg-0x10],eax" */
    {
        const unsigned char *best = NULL; int bestn = 0, r;
        const unsigned char *cand[8] = {0}; int candn[8] = {0}, nc = 0, i;
        for (r = 0; r < nrg; r++) {
            const unsigned char *p = rg[r].start, *end = rg[r].start + rg[r].size - 17;
            /* nur die Region durchsuchen, in der die Lua-Implementierung liegt (schnell, ~ms) */
            if (out->newlstr && !((const unsigned char *)out->newlstr >= rg[r].start &&
                                  (const unsigned char *)out->newlstr < rg[r].start + rg[r].size)) continue;
            for (; p < end; p++) {
                int a, b; const unsigned char *ta, *tb;
                p = (const unsigned char *)memchr(p, 0x8B, (size_t)(end - p));
                if (!p) break;
                if (p[1] != 0x05 || p[6] != 0xFF || p[7] != 0xC0 || p[8] != 0x89 || p[9] != 0x05) continue;
                if (p[14] != 0x89 || (p[15] & 0xC0) != 0x40 || p[16] != 0xF0) continue;
                memcpy(&a, p + 2, 4); memcpy(&b, p + 10, 4);
                ta = p + 6 + a; tb = p + 14 + b;
                if (ta != tb) continue;
                for (i = 0; i < nc && cand[i] != ta; i++) {}
                if (i == nc && nc < 8) { cand[nc] = ta; nc++; }
                if (i < 8) candn[i]++;
            }
        }
        for (i = 0; i < nc; i++) if (candn[i] > bestn) { bestn = candn[i]; best = cand[i]; }
        if (best && bestn >= 3) { out->stamp = (volatile int *)best; out->stamp_rva = (unsigned long long)(best - base); }
    }

    snprintf(out->info, sizeof(out->info),
             "luaS_newlstr=%s rva=0x%llx (sig=%d, via luaS_new=%s) luaS_new rva=0x%llx stamp rva=0x%llx",
             out->newlstr ? "OK" : "FEHLT", out->newlstr_rva, cnt, viacall ? "ja" : "nein",
             out->newstr_rva, out->stamp_rva);
    return out->newlstr != NULL;
}

int flua_resolve(flua_resolved *out)
{
    return flua_resolve_image((const unsigned char *)GetModuleHandleW(NULL), out);
}
