/*
 * Test der PC2MPNative-DLL ohne Spiel: baut einen lua_State im Frontier-Layout nach
 * (TValue 0x18, top@+0x10, ci@+0x20, TString-Daten@+0x18) und ruft die Exporte auf.
 * Braucht einen TCP-Echo-Server (native/test/echo_server.py) auf 127.0.0.1:<port>.
 * Aufruf: test_bridge.exe <PC2MPNative_test.dll> <port>
 */
#include "fakelua.h"

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
    fake_init();

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
