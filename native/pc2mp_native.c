/*
 * PC2MP native bridge (Lua <-> C) fuer Planet Coaster 2.
 *
 * Wird aus Lua per package.loadlib(".\\Win64\\ovldata\\PC2MP\\PC2MPNative.dll", "<fn>") geladen.
 * Das Spiel linkt Lua statisch und hat eine von Frontier veraenderte Lua 5.3 ohne Exporte.
 * Lesen/Schreiben des Lua-Stacks erfolgt direkt (Layout: frontier_lua.h, im Spiel verifiziert).
 * Strings DLL->Lua: luaS_newlstr der Exe, zur Laufzeit per Signatur gefunden (resolve.c).
 * Fallback ohne luaS_newlstr: Nachricht in 8-Byte-Chunks (pc2mp_read_i64 + string.pack in Lua).
 *
 * Exportierte lua_CFunctions (alle nicht-blockierend):
 *   pc2mp_log(s...)                 -> loggt Strings nach PC2MP_native.log
 *   pc2mp_ping()                    -> 4242
 *   pc2mp_init()                    -> 1 wenn Strings zurueckgegeben werden koennen, sonst 0
 *   pc2mp_info()                    -> Diagnose-String (oder Laenge, siehe Fallback)
 *   pc2mp_net_connect(host, port)   -> 1/0
 *   pc2mp_net_disconnect()
 *   pc2mp_net_send(json)            -> 1 = eingereiht, 0 = Fehler/Queue voll
 *   pc2mp_net_poll()                -> naechste Nachricht als String | nil
 *                                      (Fallback-Modus: Laenge als Integer, dann pc2mp_read_i64(i))
 *   pc2mp_read_i64(i)               -> Bytes [8*(i-1), 8*i) der zuletzt gepollten Nachricht als int64
 *   pc2mp_net_status()              -> status, eingehend wartend, ausgehend wartend
 *                                      (0 idle, 1 verbindet, 2 verbunden, 3 warte auf Reconnect)
 *   pc2mp_net_error()               -> letzter Fehlertext | nil
 */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "frontier_lua.h"
#include "net.h"

#define EXPORT __declspec(dllexport)

/* Nur Zugriffsverletzungen abfangen. Lua-Fehler (C++-Exceptions) muessen durchlaufen,
   sonst bleibt der Lua-Zustand inkonsistent. Ohne MSVC (zig/mingw): Pointer werden vorher
   per VirtualQuery geprueft. */
#if defined(_MSC_VER)
#define GUARD_TRY   __try
#define GUARD_CATCH __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH)
#else
#define GUARD_TRY   if (1)
#define GUARD_CATCH else
#endif

static HMODULE g_hModule = NULL;
static FILE *g_log = NULL;
static CRITICAL_SECTION g_cs;
static char g_dir[MAX_PATH] = {0};
static flua_resolved g_res;
static volatile LONG g_resolved = 0;
/* zuletzt gepollte Nachricht im Fallback-Modus */
static char *g_slot = NULL;
static size_t g_slot_len = 0;

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

/* Ist [p, p+n) lesbarer, committeter Speicher? */
static int readable(const void *p, size_t n)
{
    MEMORY_BASIC_INFORMATION mbi;
    const unsigned char *a = (const unsigned char *)p;
    while (n > 0) {
        size_t avail;
        if (!VirtualQuery(a, &mbi, sizeof(mbi))) return 0;
        if (mbi.State != MEM_COMMIT || (mbi.Protect & (PAGE_GUARD | PAGE_NOACCESS)) || mbi.Protect == 0) return 0;
        avail = (size_t)((const unsigned char *)mbi.BaseAddress + mbi.RegionSize - a);
        if (avail >= n) return 1;
        a += avail; n -= avail;
    }
    return 1;
}

static void ensure_resolved(void)
{
    if (InterlockedCompareExchange(&g_resolved, 1, 0) == 0) {
        char buf[320];
        flua_resolve(&g_res);
        snprintf(buf, sizeof(buf), "[native] resolve: %s", g_res.info);
        log_str(buf);
        InterlockedExchange(&g_resolved, 2);
    }
    while (g_resolved != 2) Sleep(0);
}

/* Liefert Zeiger auf Argument idx (1-basiert) oder NULL; *nargs = Anzahl Argumente (-1 = Layout passt nicht). */
static unsigned char *get_arg(void *L, int idx, int *nargs)
{
    unsigned char *top, *ci, *func, *base;
    *nargs = -1;
    if (!readable((unsigned char *)L + L_TOP_OFF, 0x18)) return NULL;
    top = *(unsigned char **)((unsigned char *)L + L_TOP_OFF);
    ci  = *(unsigned char **)((unsigned char *)L + L_CI_OFF);
    if (!readable(ci, 8)) return NULL;
    func = *(unsigned char **)(ci + CI_FUNC_OFF);
    base = func + TV_SIZE;
    if (top < base || (top - base) % TV_SIZE != 0 || (top - base) / TV_SIZE > 10000) return NULL;
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
    if (!ts || !readable(ts, TS_DATA_OFF)) return 0;
    if ((ts[TS_TT_OFF] & 0x3F) != raw) return 0; /* Plausibilitaetscheck */
    if (raw == LUA_TSHRSTR) *len = ts[TS_SHRLEN_OFF];
    else *len = *(size_t *)(ts + TS_LNGLEN_OFF);
    if (*len > (1u << 26) || !readable(ts + TS_DATA_OFF, *len)) return 0;
    *out = (const char *)(ts + TS_DATA_OFF);
    return 1;
}

static int tv_tointeger(unsigned char *tv, long long *out)
{
    int raw = *(int *)(tv + TV_TT_OFF) & 0x3F;
    if (raw == LUA_TNUMINT) { *out = *(long long *)tv; return 1; }
    if (raw == LUA_TNUMFLT) { *out = (long long)*(float *)tv; return 1; }
    return 0;
}

/* Frontier stempelt nach jedem Push einen globalen Zaehler in den lua_State-Extraspace. */
static void stamp(void *L)
{
    if (g_res.stamp) {
        int v = ++*g_res.stamp;
        *(int *)((unsigned char *)L + L_STAMP_OFF) = v;
    }
}

static unsigned char *push_slot(void *L)
{
    unsigned char **ptop = (unsigned char **)((unsigned char *)L + L_TOP_OFF);
    unsigned char *top = *ptop;
    memset(top, 0, TV_SIZE);
    *ptop = top + TV_SIZE;   /* lua_CFunction hat garantiert LUA_MINSTACK (20) freie Slots */
    return top;
}

static void push_int(void *L, long long v)
{
    unsigned char *top = push_slot(L);
    *(long long *)top = v;
    *(int *)(top + TV_TT_OFF) = LUA_TNUMINT;
    stamp(L);
}

static void push_nil(void *L)
{
    unsigned char *top = push_slot(L);
    *(int *)(top + TV_TT_OFF) = LUA_TNIL;
    stamp(L);
}

/* String ueber luaS_newlstr der Spiel-Lua erzeugen und pushen. 0 = nicht moeglich. */
static int push_lstring(void *L, const char *s, size_t len)
{
    unsigned char *ts, *top;
    if (!g_res.newlstr) return 0;
    ts = (unsigned char *)g_res.newlstr(L, s, len);  /* kann bei OOM per Lua-Fehler aussteigen */
    if (!ts) return 0;
    top = push_slot(L);
    *(unsigned char **)top = ts;
    *(int *)(top + TV_TT_OFF) = (ts[TS_TT_OFF] & 0x3F) | BIT_ISCOLLECTABLE;
    stamp(L);
    return 1;
}

/* String-Argument idx holen; 1 bei Erfolg */
static int arg_string(void *L, int idx, const char **s, size_t *len)
{
    int n;
    unsigned char *tv = get_arg(L, idx, &n);
    return tv && tv_tostring(tv, s, len);
}

static int arg_int(void *L, int idx, long long *v)
{
    int n;
    unsigned char *tv = get_arg(L, idx, &n);
    return tv && tv_tointeger(tv, v);
}

/* ------------------------------------------------------------------ bestehende Exporte */

/* pc2mp_log(s1, s2, ...) -> loggt alle String-Argumente in PC2MP_native.log */
EXPORT int pc2mp_log(void *L)
{
    GUARD_TRY {
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
    } GUARD_CATCH {
        log_str("[native] pc2mp_log: Exception beim Lesen des Lua-Stacks");
    }
    return 0;
}

/* pc2mp_ping() -> 4242 ; testet den Rueckweg (Zahl auf den Stack legen) */
EXPORT int pc2mp_ping(void *L)
{
    GUARD_TRY {
        push_int(L, 4242);
        return 1;
    } GUARD_CATCH {
        log_str("[native] pc2mp_ping: Exception");
    }
    return 0;
}

/* ------------------------------------------------------------------ Strings + Diagnose */

/* pc2mp_init() -> 1 wenn Strings DLL->Lua moeglich (luaS_newlstr gefunden), sonst 0 */
EXPORT int pc2mp_init(void *L)
{
    GUARD_TRY {
        ensure_resolved();
        net_init();
        push_int(L, g_res.newlstr ? 1 : 0);
        return 1;
    } GUARD_CATCH {
        log_str("[native] pc2mp_init: Exception");
    }
    return 0;
}

static int return_string(void *L, const char *s, size_t len)
{
    if (push_lstring(L, s, len)) return 1;
    /* Fallback: in den Slot kopieren, Laenge zurueckgeben */
    EnterCriticalSection(&g_cs);
    free(g_slot);
    g_slot = (char *)malloc(len ? len : 1);
    if (g_slot) memcpy(g_slot, s, len);
    g_slot_len = g_slot ? len : 0;
    LeaveCriticalSection(&g_cs);
    push_int(L, (long long)g_slot_len);
    return 1;
}

/* pc2mp_info() -> Diagnose-Text */
EXPORT int pc2mp_info(void *L)
{
    GUARD_TRY {
        ensure_resolved();
        return return_string(L, g_res.info, strlen(g_res.info));
    } GUARD_CATCH {
        log_str("[native] pc2mp_info: Exception");
    }
    return 0;
}

/* pc2mp_read_i64(i) -> 8 Bytes der zuletzt per Fallback gelieferten Nachricht (little endian) */
EXPORT int pc2mp_read_i64(void *L)
{
    GUARD_TRY {
        long long i = 0, v = 0;
        size_t off;
        if (!arg_int(L, 1, &i) || i < 1) { push_nil(L); return 1; }
        off = (size_t)(i - 1) * 8;
        EnterCriticalSection(&g_cs);
        if (g_slot && off < g_slot_len) {
            size_t n = g_slot_len - off; if (n > 8) n = 8;
            memcpy(&v, g_slot + off, n);
        }
        LeaveCriticalSection(&g_cs);
        push_int(L, v);
        return 1;
    } GUARD_CATCH {
        log_str("[native] pc2mp_read_i64: Exception");
    }
    return 0;
}

/* ------------------------------------------------------------------ Netzwerk */

/* pc2mp_net_connect(host, port) -> 1/0 */
EXPORT int pc2mp_net_connect(void *L)
{
    GUARD_TRY {
        const char *host; size_t hl; long long port = 0;
        int ok = arg_string(L, 1, &host, &hl) && arg_int(L, 2, &port) && net_connect(host, hl, (int)port);
        char buf[320];
        snprintf(buf, sizeof(buf), "[native] net_connect(%.*s, %lld) -> %d", ok ? (int)hl : 0, ok ? host : "", port, ok);
        log_str(buf);
        push_int(L, ok);
        return 1;
    } GUARD_CATCH {
        log_str("[native] pc2mp_net_connect: Exception");
    }
    return 0;
}

EXPORT int pc2mp_net_disconnect(void *L)
{
    (void)L;
    net_disconnect();
    log_str("[native] net_disconnect");
    return 0;
}

/* pc2mp_net_send(json) -> 1 eingereiht / 0 */
EXPORT int pc2mp_net_send(void *L)
{
    GUARD_TRY {
        const char *s; size_t len;
        int ok = arg_string(L, 1, &s, &len) && net_send(s, len);
        push_int(L, ok);
        return 1;
    } GUARD_CATCH {
        log_str("[native] pc2mp_net_send: Exception");
    }
    return 0;
}

/* pc2mp_net_poll() -> String | nil  (Fallback: Laenge als Integer) */
EXPORT int pc2mp_net_poll(void *L)
{
    GUARD_TRY {
        size_t len = 0;
        char *m;
        ensure_resolved();
        m = net_poll(&len);
        if (!m) { push_nil(L); return 1; }
        return_string(L, m, len);
        net_free(m);
        return 1;
    } GUARD_CATCH {
        log_str("[native] pc2mp_net_poll: Exception");
    }
    return 0;
}

/* pc2mp_net_status() -> status, wartend_ein, wartend_aus */
EXPORT int pc2mp_net_status(void *L)
{
    GUARD_TRY {
        push_int(L, net_status());
        push_int(L, (long long)net_pending_in());
        push_int(L, (long long)net_pending_out());
        return 3;
    } GUARD_CATCH {
        log_str("[native] pc2mp_net_status: Exception");
    }
    return 0;
}

/* pc2mp_net_error() -> letzter Fehlertext | nil */
EXPORT int pc2mp_net_error(void *L)
{
    GUARD_TRY {
        char buf[256];
        net_last_error(buf, sizeof(buf));
        if (!buf[0]) { push_nil(L); return 1; }
        ensure_resolved();
        return return_string(L, buf, strlen(buf));
    } GUARD_CATCH {
        log_str("[native] pc2mp_net_error: Exception");
    }
    return 0;
}

#ifdef PC2MP_TEST
/* Nur im Test-Build: Fake-luaS_newlstr einsetzen (NULL = Chunk-Fallback testen). */
EXPORT void pc2mp_test_set_newlstr(luaS_newlstr_fn f)
{
    ensure_resolved();
    g_res.newlstr = f;
}
#endif

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
