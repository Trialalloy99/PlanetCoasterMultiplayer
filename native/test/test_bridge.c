/*
 * Test der PC2MPNative-DLL ohne Spiel: baut einen lua_State im Frontier-Layout nach
 * (TValue 0x18, top@+0x10, ci@+0x20, TString-Daten@+0x18) und ruft die Exporte auf.
 * Braucht einen TCP-Echo-Server (native/test/echo_server.py) auf 127.0.0.1:<port>.
 * Aufruf: test_bridge.exe <PC2MPNative_test.dll> <port>
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../frontier_lua.h"

typedef int (*cfn)(void *L);
typedef void (*setfn)(luaS_newlstr_fn);

static unsigned char g_mem[0x200 + 64 * TV_SIZE];
static unsigned char *L, *ci, *stack;
static int failures = 0;

#define CHECK(c, ...) do { if (!(c)) { failures++; printf("FAIL %s:%d ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* Fake luaS_newlstr: TString wie die Spiel-Lua (kurz <= 40 -> tt 0x04, sonst 0x14) */
static void *fake_newlstr(void *Ls, const char *s, size_t len)
{
    unsigned char *ts = (unsigned char *)calloc(1, TS_DATA_OFF + len + 1);
    (void)Ls;
    ts[TS_TT_OFF] = len <= FLUA_MAXSHORTLEN ? LUA_TSHRSTR : LUA_TLNGSTR;
    if (len <= FLUA_MAXSHORTLEN) ts[TS_SHRLEN_OFF] = (unsigned char)len;
    else *(size_t *)(ts + TS_LNGLEN_OFF) = len;
    memcpy(ts + TS_DATA_OFF, s, len);
    return ts;
}

static unsigned char *mkstr(const char *s) { return (unsigned char *)fake_newlstr(NULL, s, strlen(s)); }

/* Aufrufrahmen: func-Slot + Argumente; liefert Zeiger auf ersten Rueckgabewert */
static unsigned char *frame_begin(void)
{
    memset(stack, 0, 64 * TV_SIZE);
    *(unsigned char **)(ci + CI_FUNC_OFF) = stack;           /* func = stack[0] */
    *(unsigned char **)(L + L_TOP_OFF) = stack + TV_SIZE;     /* keine Argumente */
    return stack + TV_SIZE;
}
static void arg_str(const char *s)
{
    unsigned char **ptop = (unsigned char **)(L + L_TOP_OFF);
    unsigned char *ts = mkstr(s);
    *(unsigned char **)*ptop = ts;
    *(int *)(*ptop + TV_TT_OFF) = ts[TS_TT_OFF] | BIT_ISCOLLECTABLE;
    *ptop += TV_SIZE;
}
static void arg_int(long long v)
{
    unsigned char **ptop = (unsigned char **)(L + L_TOP_OFF);
    *(long long *)*ptop = v;
    *(int *)(*ptop + TV_TT_OFF) = LUA_TNUMINT;
    *ptop += TV_SIZE;
}
static int call(cfn f, unsigned char **ret)
{
    unsigned char *before = *(unsigned char **)(L + L_TOP_OFF);
    int n = f(L);
    unsigned char *after = *(unsigned char **)(L + L_TOP_OFF);
    if (after - before != n * TV_SIZE) { failures++; printf("FAIL: Rueckgabeanzahl %d passt nicht zu top-Delta %d\n", n, (int)((after - before) / TV_SIZE)); }
    *ret = before;
    return n;
}
static int tt(unsigned char *tv) { return *(int *)(tv + TV_TT_OFF); }
static long long ival(unsigned char *tv) { return *(long long *)tv; }
static const char *sval(unsigned char *tv, size_t *len)
{
    unsigned char *ts = *(unsigned char **)tv;
    *len = (ts[TS_TT_OFF] & 0x3F) == LUA_TSHRSTR ? ts[TS_SHRLEN_OFF] : *(size_t *)(ts + TS_LNGLEN_OFF);
    return (const char *)(ts + TS_DATA_OFF);
}

int main(int argc, char **argv)
{
    HMODULE dll;
    cfn ping, init, info, conn, disc, send, poll, status, err, readi64;
    setfn setnl;
    unsigned char *r;
    int n, i, port;
    char big[5000];
    if (argc < 3) { printf("usage: test_bridge <dll> <port>\n"); return 2; }
    port = atoi(argv[2]);
    L = g_mem + 0x40; ci = g_mem + 0x100; stack = g_mem + 0x200;
    *(unsigned char **)(L + L_CI_OFF) = ci;

    dll = LoadLibraryA(argv[1]);
    if (!dll) { printf("DLL nicht ladbar (%lu)\n", GetLastError()); return 1; }
#define GP(v, name) v = (cfn)(void *)GetProcAddress(dll, name); if (!v) { printf("Export fehlt: %s\n", name); return 1; }
    GP(ping, "pc2mp_ping"); GP(init, "pc2mp_init"); GP(info, "pc2mp_info"); GP(conn, "pc2mp_net_connect");
    GP(disc, "pc2mp_net_disconnect"); GP(send, "pc2mp_net_send"); GP(poll, "pc2mp_net_poll");
    GP(status, "pc2mp_net_status"); GP(err, "pc2mp_net_error"); GP(readi64, "pc2mp_read_i64");
    setnl = (setfn)(void *)GetProcAddress(dll, "pc2mp_test_set_newlstr");
    if (!setnl) { printf("Test-DLL ohne pc2mp_test_set_newlstr\n"); return 1; }

    frame_begin(); n = call(ping, &r);
    CHECK(n == 1 && tt(r) == LUA_TNUMINT && ival(r) == 4242, "ping");

    /* Im Testprozess gibt es kein luaS_newlstr -> init meldet 0 (Fallback) */
    frame_begin(); n = call(init, &r);
    CHECK(n == 1 && tt(r) == LUA_TNUMINT && ival(r) == 0, "init ohne Spiel-Lua sollte 0 liefern, ist %lld", ival(r));

    /* String-Pfad mit Fake-luaS_newlstr */
    setnl(fake_newlstr);
    frame_begin(); n = call(info, &r);
    {
        size_t len; const char *s;
        CHECK(n == 1 && (tt(r) & 0x3F) == LUA_TLNGSTR && (tt(r) & BIT_ISCOLLECTABLE), "info tt=0x%x", tt(r));
        s = sval(r, &len);
        printf("info: %.*s\n", (int)len, s);
    }

    /* Netzwerk */
    frame_begin(); arg_str("127.0.0.1"); arg_int(port); n = call(conn, &r);
    CHECK(n == 1 && ival(r) == 1, "connect");
    for (i = 0; i < 100; i++) {
        frame_begin(); call(status, &r);
        if (ival(r) == 2) break;
        Sleep(50);
    }
    CHECK(ival(r) == 2, "nicht verbunden (status %lld)", ival(r));

    /* kurze Nachricht, Nachricht mit Zeilenumbruch, lange Nachricht (> 40 -> long string) */
    for (i = 0; i < (int)sizeof(big) - 1; i++) big[i] = (char)('a' + i % 26);
    big[sizeof(big) - 1] = 0;
    frame_begin(); arg_str("{\"t\":\"hi\"}"); call(send, &r); CHECK(ival(r) == 1, "send1");
    frame_begin(); arg_str("{\"a\":1,\n\"b\":2}"); call(send, &r); CHECK(ival(r) == 1, "send2");
    frame_begin(); arg_str(big); call(send, &r); CHECK(ival(r) == 1, "send3");
    {
        const char *expect[3];
        int got = 0, tries;
        expect[0] = "{\"t\":\"hi\"}"; expect[1] = "{\"a\":1, \"b\":2}"; expect[2] = big;
        for (tries = 0; tries < 200 && got < 3; tries++) {
            frame_begin(); n = call(poll, &r);
            if (tt(r) == LUA_TNIL) { Sleep(20); continue; }
            {
                size_t len; const char *s = sval(r, &len);
                CHECK(len == strlen(expect[got]) && memcmp(s, expect[got], len) == 0,
                      "Echo %d falsch: '%.*s'", got, (int)(len > 60 ? 60 : len), s);
                CHECK((len <= FLUA_MAXSHORTLEN) == ((tt(r) & 0x3F) == LUA_TSHRSTR), "String-Typ passt nicht zur Laenge");
            }
            got++;
        }
        CHECK(got == 3, "nur %d von 3 Echos", got);
    }

    /* Fallback: ohne luaS_newlstr -> Laenge + read_i64 */
    setnl(NULL);
    frame_begin(); arg_str("{\"fallback\":true}"); call(send, &r);
    for (i = 0; i < 200; i++) {
        frame_begin(); call(poll, &r);
        if (tt(r) != LUA_TNIL) break;
        Sleep(20);
    }
    CHECK(tt(r) == LUA_TNUMINT && ival(r) == 17, "Fallback-Laenge %lld", ival(r));
    {
        char buf[32] = {0}; int k;
        for (k = 1; k <= 3; k++) {
            long long v;
            frame_begin(); arg_int(k); call(readi64, &r);
            v = ival(r); memcpy(buf + (k - 1) * 8, &v, 8);
        }
        CHECK(memcmp(buf, "{\"fallback\":true}", 17) == 0, "Fallback-Inhalt '%s'", buf);
    }

    /* Stack-Layout-Fehler duerfen nicht crashen: ci zeigt ins Leere */
    *(unsigned char **)(L + L_CI_OFF) = (unsigned char *)(ULONG_PTR)0x10;
    {
        cfn logf = (cfn)(void *)GetProcAddress(dll, "pc2mp_log");
        logf(L); /* darf nur loggen */
    }
    *(unsigned char **)(L + L_CI_OFF) = ci;

    frame_begin(); call(disc, &r);
    printf(failures ? "\n%d FEHLER\n" : "\nALLE TESTS OK\n", failures);
    return failures ? 1 : 0;
}
