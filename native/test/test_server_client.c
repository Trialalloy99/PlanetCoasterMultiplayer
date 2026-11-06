/*
 * Integrationstest DLL <-> echter Server (server/pc2mp_server.py), gesteuert von test_with_server.py.
 * Ablauf: hello automatisch beim Connect -> welcome + caughtUp, action -> Echo mit seq,
 * dann (Orchestrator startet Server neu) Auto-Reconnect, hello erneut -> Catch-up der Aktion.
 * Aufruf: test_server_client.exe <PC2MPNative_test.dll> <port>
 */
#include "fakelua.h"

static cfn f_poll, f_status;

/* Wartet bis eine Nachricht mit Substring kommt; kopiert sie nach out. */
static int wait_msg(const char *needle, char *out, size_t cap, int ms)
{
    unsigned char *r;
    int waited = 0;
    while (waited < ms) {
        frame_begin(); call(f_poll, &r);
        if (tt(r) == LUA_TNIL) { Sleep(20); waited += 20; continue; }
        {
            size_t len; const char *s = sval(r, &len);
            printf("  <- %.*s\n", (int)(len > 160 ? 160 : len), s);
            if (strstr(s, needle)) {
                size_t n = len < cap - 1 ? len : cap - 1;
                memcpy(out, s, n); out[n] = 0;
                return 1;
            }
        }
    }
    return 0;
}

static long long connects(void)
{
    unsigned char *r;
    frame_begin(); call(f_status, &r);
    return ival(r + 3 * TV_SIZE);
}

int main(int argc, char **argv)
{
    HMODULE dll;
    cfn conn, send, hello, disc;
    setfn setnl;
    unsigned char *r;
    char buf[4096];
    int i;
    if (argc < 3) { printf("usage: test_server_client <dll> <port>\n"); return 2; }
    fake_init();
    dll = LoadLibraryA(argv[1]);
    if (!dll) { printf("DLL nicht ladbar\n"); return 1; }
    conn = (cfn)(void *)GetProcAddress(dll, "pc2mp_net_connect");
    send = (cfn)(void *)GetProcAddress(dll, "pc2mp_net_send");
    hello = (cfn)(void *)GetProcAddress(dll, "pc2mp_net_set_hello");
    disc = (cfn)(void *)GetProcAddress(dll, "pc2mp_net_disconnect");
    f_poll = (cfn)(void *)GetProcAddress(dll, "pc2mp_net_poll");
    f_status = (cfn)(void *)GetProcAddress(dll, "pc2mp_net_status");
    setnl = (setfn)(void *)GetProcAddress(dll, "pc2mp_test_set_newlstr");
    if (!conn || !send || !hello || !f_poll || !f_status || !setnl) { printf("Exporte fehlen\n"); return 1; }
    setnl(fake_newlstr);

    frame_begin(); arg_str("{\"t\":\"hello\",\"v\":1,\"name\":\"BridgeTest\",\"park\":\"bridgetest\",\"lastSeq\":0}");
    call(hello, &r); CHECK(ival(r) == 1, "set_hello");
    frame_begin(); arg_str("127.0.0.1"); arg_int(atoi(argv[2])); call(conn, &r);
    CHECK(ival(r) == 1, "connect");

    CHECK(wait_msg("\"welcome\"", buf, sizeof(buf), 5000), "kein welcome");
    CHECK(wait_msg("\"caughtUp\"", buf, sizeof(buf), 5000), "kein caughtUp");
    CHECK(connects() == 1, "connect count %lld", connects());

    frame_begin();
    arg_str("{\"t\":\"action\",\"cseq\":1,\"action\":{\"op\":\"commit\",\"calls\":[{\"m\":\"CreateNewPart\",\"a\":{\"1\":\"SceneryTree_Oak_03\"}}],\"objects\":[{\"partID\":123,\"pos\":[1,2,3],\"rot\":[0,0,0],\"scale\":1}]}}");
    call(send, &r); CHECK(ival(r) == 1, "send action");
    CHECK(wait_msg("\"seq\"", buf, sizeof(buf), 5000) && strstr(buf, "\"action\""), "kein action-Echo");

    printf("RESTART\n"); fflush(stdout);   /* Orchestrator startet den Server neu */

    for (i = 0; i < 300 && connects() < 2; i++) {
        if (i % 20 == 0) {
            cfn ferr = (cfn)(void *)GetProcAddress(dll, "pc2mp_net_error");
            unsigned char *e; size_t el = 0; const char *es = "";
            frame_begin(); call(f_status, &r);
            printf("  status=%lld in=%lld out=%lld connects=%lld", ival(r), ival(r + TV_SIZE), ival(r + 2 * TV_SIZE), ival(r + 3 * TV_SIZE));
            frame_begin(); call(ferr, &e);
            if (tt(e) != LUA_TNIL) es = sval(e, &el);
            printf(" err='%.*s'\n", (int)el, es); fflush(stdout);
        }
        Sleep(50);
    }
    CHECK(connects() >= 2, "kein Auto-Reconnect (connects=%lld)", connects());
    /* hello wurde automatisch erneut gesendet (lastSeq 0) -> Catch-up enthaelt die Aktion */
    CHECK(wait_msg("\"welcome\"", buf, sizeof(buf), 5000), "kein welcome nach Reconnect");
    CHECK(wait_msg("SceneryTree_Oak_03", buf, sizeof(buf), 5000), "Catch-up ohne die Aktion");
    CHECK(wait_msg("\"caughtUp\"", buf, sizeof(buf), 5000), "kein caughtUp nach Reconnect");

    frame_begin(); call(disc, &r);
    printf(failures ? "\n%d FEHLER\n" : "\nSERVER-INTEGRATION OK\n", failures);
    fflush(stdout);
    return failures ? 1 : 0;
}
