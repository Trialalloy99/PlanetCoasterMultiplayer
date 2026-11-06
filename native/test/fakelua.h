/* Gemeinsame Test-Helfer: lua_State im Frontier-Layout nachgebaut (nur fuer Tests). */
#ifndef PC2MP_FAKELUA_H
#define PC2MP_FAKELUA_H
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

static void fake_init(void)
{
    L = g_mem + 0x40; ci = g_mem + 0x100; stack = g_mem + 0x200;
    *(unsigned char **)(L + L_CI_OFF) = ci;
}

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

static unsigned char *frame_begin(void)
{
    memset(stack, 0, 64 * TV_SIZE);
    *(unsigned char **)(ci + CI_FUNC_OFF) = stack;
    *(unsigned char **)(L + L_TOP_OFF) = stack + TV_SIZE;
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
#endif
