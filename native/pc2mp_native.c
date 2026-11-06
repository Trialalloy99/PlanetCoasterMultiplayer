/*
 * PC2MP native bridge (Lua <-> C) fuer Planet Coaster 2.
 *
 * Wird aus Lua per package.loadlib(".\\Win64\\ovldata\\PC2MP\\PC2MPNative.dll", "<fn>") geladen.
 * Das Spiel linkt Lua statisch und hat eine von Frontier veraenderte Lua 5.3,
 * daher KEINE Lua-Bibliothek: wir lesen/schreiben den Lua-Stack direkt.
 *
 * Layout (aus ACSEDebug.dll fuer Planet Zoo abgeleitet, fuer PC2 noch zu verifizieren):
 *   lua_State: +0x10 top (TValue*), +0x20 ci (CallInfo*)
 *   CallInfo:  +0x00 func (TValue*)
 *   TValue:    24 Byte, +0x00 value, +0x10 tt (int)
 *   TString:   +0x08 tt (byte), +0x0B shrlen (byte), +0x10 lnglen (size_t), +0x18 Daten
 * Alle Zugriffe laufen in __try/__except, damit ein falsches Layout nicht crasht.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define EXPORT __declspec(dllexport)

#define TV_SIZE        0x18
#define TV_TT_OFF      0x10
#define L_TOP_OFF      0x10
#define L_CI_OFF       0x20
#define CI_FUNC_OFF    0x00
#define TS_TT_OFF      0x08
#define TS_SHRLEN_OFF  0x0B
#define TS_LNGLEN_OFF  0x10
#define TS_DATA_OFF    0x18

/* Lua 5.3 Typ-Tags */
#define LUA_TNIL       0
#define LUA_TBOOLEAN   1
#define LUA_TNUMBER    3
#define LUA_TSTRING    4
#define LUA_TSHRSTR    (LUA_TSTRING | (0 << 4))
#define LUA_TLNGSTR    (LUA_TSTRING | (1 << 4))
#define LUA_TNUMINT    (LUA_TNUMBER | (1 << 4))
#define BIT_ISCOLLECTABLE (1 << 6)

static HMODULE g_hModule = NULL;
static FILE *g_log = NULL;
static CRITICAL_SECTION g_cs;
static char g_dir[MAX_PATH] = {0};

static void open_log(void)
{
    char path[MAX_PATH];
    if (g_log) return;
    snprintf(path, sizeof(path), "%sPC2MP_native.log", g_dir);
    g_log = fopen(path, "a");
}

static void log_line(const char *msg, size_t len)
{
    SYSTEMTIME t;
    EnterCriticalSection(&g_cs);
    open_log();
    if (g_log) {
        GetLocalTime(&t);
        fprintf(g_log, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
        fwrite(msg, 1, len, g_log);
        fputc('\n', g_log);
        fflush(g_log);
    }
    LeaveCriticalSection(&g_cs);
}

static void log_str(const char *msg) { log_line(msg, strlen(msg)); }

/* Liefert Zeiger auf Argument idx (1-basiert) oder NULL; *nargs = Anzahl Argumente. */
static unsigned char *get_arg(void *L, int idx, int *nargs)
{
    unsigned char *top  = *(unsigned char **)((unsigned char *)L + L_TOP_OFF);
    unsigned char *ci   = *(unsigned char **)((unsigned char *)L + L_CI_OFF);
    unsigned char *func = *(unsigned char **)(ci + CI_FUNC_OFF);
    unsigned char *base = func + TV_SIZE;
    if (top < base || (top - base) % TV_SIZE != 0 || (top - base) / TV_SIZE > 10000) {
        *nargs = -1; /* Layout passt nicht */
        return NULL;
    }
    *nargs = (int)((top - base) / TV_SIZE);
    if (idx < 1 || idx > *nargs) return NULL;
    return base + (size_t)(idx - 1) * TV_SIZE;
}

/* Liest einen Lua-String aus einem TValue. Gibt 1 bei Erfolg. */
static int tv_tostring(unsigned char *tv, const char **out, size_t *len)
{
    int tt = *(int *)(tv + TV_TT_OFF);
    unsigned char *ts;
    int raw = tt & 0x3F;
    if (raw != LUA_TSHRSTR && raw != LUA_TLNGSTR) return 0;
    ts = *(unsigned char **)tv;
    if (!ts) return 0;
    if ((ts[TS_TT_OFF] & 0x3F) != raw) return 0; /* Plausibilitaetscheck */
    if (raw == LUA_TSHRSTR) *len = ts[TS_SHRLEN_OFF];
    else *len = *(size_t *)(ts + TS_LNGLEN_OFF);
    if (*len > (1u << 24)) return 0;
    *out = (const char *)(ts + TS_DATA_OFF);
    return 1;
}

/* Legt eine Ganzzahl auf den Lua-Stack (kein GC-Objekt, daher ungefaehrlich). */
static void push_int(void *L, long long v)
{
    unsigned char **ptop = (unsigned char **)((unsigned char *)L + L_TOP_OFF);
    unsigned char *top = *ptop;
    memset(top, 0, TV_SIZE);
    *(long long *)top = v;
    *(int *)(top + TV_TT_OFF) = LUA_TNUMINT;
    *ptop = top + TV_SIZE;
}

/* pc2mp_log(s1, s2, ...) -> loggt alle String-Argumente in PC2MP_native.log */
EXPORT int pc2mp_log(void *L)
{
    __try {
        int n = 0, i;
        get_arg(L, 0, &n);
        if (n < 0) { log_str("[native] pc2mp_log: Stack-Layout passt nicht"); return 0; }
        for (i = 1; i <= n; i++) {
            const char *s; size_t len;
            unsigned char *tv = get_arg(L, i, &n);
            if (tv && tv_tostring(tv, &s, &len)) log_line(s, len);
            else {
                char buf[96];
                snprintf(buf, sizeof(buf), "[native] Arg %d ist kein String (tt=0x%x)", i,
                         tv ? *(int *)(tv + TV_TT_OFF) : -1);
                log_str(buf);
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        log_str("[native] pc2mp_log: Exception beim Lesen des Lua-Stacks");
    }
    return 0;
}

/* pc2mp_ping() -> 4242 ; testet den Rueckweg (Zahl auf den Stack legen) */
EXPORT int pc2mp_ping(void *L)
{
    __try {
        push_int(L, 4242);
        return 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        log_str("[native] pc2mp_ping: Exception");
        return 0;
    }
}

/* Dummy, damit require-Sucher die DLL nicht als Lua-Modul initialisieren. */
EXPORT int luaopen_IGNORE_PC2MPNative(void *L) { (void)L; return 0; }

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        char *slash;
        g_hModule = hinst;
        DisableThreadLibraryCalls(hinst);
        InitializeCriticalSection(&g_cs);
        GetModuleFileNameA(hinst, g_dir, MAX_PATH);
        slash = strrchr(g_dir, '\\');
        if (slash) slash[1] = '\0';
        log_str("==== [native] PC2MPNative.dll geladen (package.loadlib funktioniert) ====");
    } else if (reason == DLL_PROCESS_DETACH) {
        if (g_log) { fclose(g_log); g_log = NULL; }
        /* CriticalSection bewusst nicht loeschen (Prozessende) */
    }
    return TRUE;
}
