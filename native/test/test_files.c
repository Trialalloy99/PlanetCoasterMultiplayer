/*
 * Test der Datei- und Spielstand-Exporte (#14/#3) mit Fake-lua_State.
 * Aufruf: test_files.exe <PC2MPNative_test.dll> <temp-saves-dir> <sha256 von test.park2>
 * Erwartet in <temp-saves-dir> eine Datei test.park2 (legt test_with_files.py an).
 * PC2MP_TEST_SAVES_DIR muss auf <temp-saves-dir> zeigen (Test-Build nutzt nie den echten Ordner).
 */
#include "fakelua.h"

static cfn get(HMODULE d, const char *n)
{
    cfn f = (cfn)(void *)GetProcAddress(d, n);
    if (!f) { printf("Export fehlt: %s\n", n); exit(1); }
    return f;
}

static int call_str(cfn f, const char *a1, char *out, size_t cap)   /* 1 = String zurueck */
{
    unsigned char *r; size_t len; const char *s;
    frame_begin(); if (a1) arg_str(a1); call(f, &r);
    if ((tt(r) & 0x0F) != LUA_TSTRING) return 0;
    s = sval(r, &len);
    if (out) { size_t n = len < cap - 1 ? len : cap - 1; memcpy(out, s, n); out[n] = 0; }
    return 1;
}

int main(int argc, char **argv)
{
    HMODULE dll;
    cfn wfile, rfile, sdir, slist, sinfo, sread, swrite, sfinish, sabort;
    setfn setnl;
    unsigned char *r;
    char buf[4096], info[512];
    long long chunks = 0, i;
    char *p;
    if (argc < 4) { printf("usage: test_files <dll> <savesdir> <sha256>\n"); return 2; }
    fake_init();
    dll = LoadLibraryA(argv[1]);
    if (!dll) { printf("DLL nicht ladbar\n"); return 1; }
    wfile = get(dll, "pc2mp_write_file"); rfile = get(dll, "pc2mp_read_file"); sdir = get(dll, "pc2mp_saves_dir");
    slist = get(dll, "pc2mp_save_list"); sinfo = get(dll, "pc2mp_save_info"); sread = get(dll, "pc2mp_save_read_chunk");
    swrite = get(dll, "pc2mp_save_write_chunk"); sfinish = get(dll, "pc2mp_save_finish"); sabort = get(dll, "pc2mp_save_abort");
    setnl = (setfn)(void *)GetProcAddress(dll, "pc2mp_test_set_newlstr");
    setnl(fake_newlstr);

    /* --- Datendateien */
    frame_begin(); arg_str("test_state.json"); arg_str("{\"lastSeq\":42,\"map\":{\"n1\":20166}}"); call(wfile, &r);
    CHECK(ival(r) == 1, "write_file");
    CHECK(call_str(rfile, "test_state.json", buf, sizeof(buf)) && strcmp(buf, "{\"lastSeq\":42,\"map\":{\"n1\":20166}}") == 0, "read_file Inhalt '%s'", buf);
    frame_begin(); arg_str("test_state.json"); arg_str("v2"); call(wfile, &r);
    CHECK(ival(r) == 1 && call_str(rfile, "test_state.json", buf, sizeof(buf)) && strcmp(buf, "v2") == 0, "ueberschreiben atomar");
    {
        const char *bad[] = { "../evil.txt", "a\\b.txt", "a/b.txt", ".hidden", "", "x..y", "C:evil", NULL };
        int k;
        for (k = 0; bad[k]; k++) {
            frame_begin(); arg_str(bad[k]); arg_str("x"); call(wfile, &r);
            CHECK(ival(r) == 0, "Name '%s' muss abgelehnt werden", bad[k]);
        }
    }
    frame_begin(); arg_str("fehlt.json"); call(rfile, &r);
    CHECK(tt(r) == LUA_TNIL, "fehlende Datei -> nil");

    /* --- Spielstaende */
    CHECK(call_str(sdir, NULL, buf, sizeof(buf)) && strstr(buf, argv[2]) != NULL, "saves_dir = Test-Ordner ('%s')", buf);
    CHECK(call_str(slist, NULL, buf, sizeof(buf)) && strstr(buf, "\"name\":\"test.park2\""), "save_list enthaelt test.park2: %s", buf);
    CHECK(call_str(sinfo, "test.park2", info, sizeof(info)), "save_info");
    CHECK(strstr(info, argv[3]) != NULL, "SHA-256 stimmt mit Python ueberein: %s", info);
    p = strstr(info, "\"chunks\":");
    if (p) chunks = atoll(p + 9);
    CHECK(chunks == 3, "1,3 MB -> 3 Chunks (ist %lld)", chunks);

    /* alle Chunks lesen und unter neuem Namen schreiben */
    for (i = 0; i < chunks; i++) {
        unsigned char *rr; size_t bl; const char *b64; char *copy;
        frame_begin(); arg_str("test.park2"); arg_int(i); call(sread, &rr);
        if ((tt(rr) & 0x0F) != LUA_TSTRING) { CHECK(0, "Chunk %lld nicht lesbar", i); break; }
        b64 = sval(rr, &bl);
        copy = (char *)malloc(bl + 1); memcpy(copy, b64, bl); copy[bl] = 0;
        frame_begin(); arg_str("empfangen.park2"); arg_int(i); arg_str(copy); call(swrite, &rr);
        CHECK(ival(rr) == 1, "Chunk %lld schreiben", i);
        free(copy);
    }
    frame_begin(); arg_str("test.park2"); arg_int(chunks); call(sread, &r);
    CHECK(tt(r) == LUA_TNIL, "Chunk hinter dem Ende -> nil");

    frame_begin(); arg_str("empfangen.park2"); arg_str("0000000000000000000000000000000000000000000000000000000000000000"); call(sfinish, &r);
    CHECK(ival(r) == 0, "falscher Hash wird abgelehnt");
    /* Temp-Datei wurde bei falschem Hash verworfen -> neu uebertragen */
    for (i = 0; i < chunks; i++) {
        unsigned char *rr; size_t bl; const char *b64; char *copy;
        frame_begin(); arg_str("test.park2"); arg_int(i); call(sread, &rr);
        b64 = sval(rr, &bl); copy = (char *)malloc(bl + 1); memcpy(copy, b64, bl); copy[bl] = 0;
        frame_begin(); arg_str("empfangen.park2"); arg_int(i); arg_str(copy); call(swrite, &rr);
        free(copy);
    }
    frame_begin(); arg_str("empfangen.park2"); arg_str(argv[3]); call(sfinish, &r);
    CHECK(ival(r) == 1, "richtiger Hash -> Spielstand angelegt");
    CHECK(call_str(sinfo, "empfangen.park2", info, sizeof(info)) && strstr(info, argv[3]), "empfangene Datei identisch");

    /* nie ueberschreiben */
    frame_begin(); arg_str("test.park2"); arg_int(0); arg_str("QUJD"); call(swrite, &r);
    frame_begin(); arg_str("test.park2"); arg_str(argv[3]); call(sfinish, &r);
    CHECK(ival(r) == 0, "vorhandener Spielstand wird nicht ueberschrieben");
    frame_begin(); arg_str("test.park2"); call(sabort, &r);
    CHECK(call_str(sinfo, "test.park2", info, sizeof(info)) && strstr(info, argv[3]), "Original unveraendert");

    /* falscher Typ */
    frame_begin(); arg_str("evil.exe"); arg_int(0); arg_str("QUJD"); call(swrite, &r);
    CHECK(ival(r) == 0, "nur .park2 erlaubt");

    printf(failures ? "\n%d FEHLER\n" : "\nDATEI-TESTS OK\n", failures);
    return failures ? 1 : 0;
}
