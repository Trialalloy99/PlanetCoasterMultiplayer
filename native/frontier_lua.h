/*
 * Laufzeit-Layout der von Frontier veraenderten Lua 5.3 in Planet Coaster 2.
 * Verifiziert: statisch (Disassembly der Exe) und im Spiel (docs/findings/ingame-test-2026-11-06.md).
 */
#ifndef PC2MP_FRONTIER_LUA_H
#define PC2MP_FRONTIER_LUA_H

#include <stddef.h>

#define TV_SIZE        0x18   /* TValue: 8 Byte value + 8 Byte (vector-Erweiterung) + tt */
#define TV_TT_OFF      0x10
#define L_TOP_OFF      0x10   /* lua_State.top   (TValue*) */
#define L_CI_OFF       0x20   /* lua_State.ci    (CallInfo*) */
#define L_STAMP_OFF    (-0x10) /* LUAI_EXTRASPACE: Frontier schreibt hier nach jedem Push einen globalen Zaehler */
#define CI_FUNC_OFF    0x00   /* CallInfo.func   (TValue*) */
#define TS_TT_OFF      0x08
#define TS_SHRLEN_OFF  0x0B
#define TS_LNGLEN_OFF  0x10
#define TS_DATA_OFF    0x18

#define LUA_TNIL       0
#define LUA_TBOOLEAN   1
#define LUA_TNUMBER    3
#define LUA_TSTRING    4
#define LUA_TSHRSTR    (LUA_TSTRING | (0 << 4))
#define LUA_TLNGSTR    (LUA_TSTRING | (1 << 4))
#define LUA_TNUMFLT    (LUA_TNUMBER | (0 << 4))
#define LUA_TNUMINT    (LUA_TNUMBER | (1 << 4))
#define BIT_ISCOLLECTABLE (1 << 6)

/* LUAI_MAXSHORTLEN der Spiel-Lua (aus luaS_newlstr: cmp r8, 0x28) */
#define FLUA_MAXSHORTLEN 40

/* TString *luaS_newlstr(lua_State *L, const char *str, size_t l) */
typedef void *(*luaS_newlstr_fn)(void *L, const char *str, size_t len);

typedef struct {
    luaS_newlstr_fn newlstr;     /* NULL = nicht gefunden -> Chunk-Fallback */
    volatile int   *stamp;       /* globaler Stack-Stempel (optional) */
    unsigned long long newlstr_rva, newstr_rva, stamp_rva;
    char            info[256];   /* Text fuer Log/Diagnose */
} flua_resolved;

/* resolve.c */
int flua_resolve(flua_resolved *out);                 /* scannt das Exe-Image des eigenen Prozesses */
int flua_resolve_image(const unsigned char *base, flua_resolved *out); /* fuer Tests: beliebiges gemapptes Image */

#endif
