/*
 * Netzwerk-Thread der PC2MP-DLL.
 * - Lua ruft nie blockierend: send() haengt an die Ausgangs-Queue, poll() nimmt aus der Eingangs-Queue.
 * - Protokoll: TCP, eine JSON-Nachricht pro Zeile ('\n'). Zeilenumbrueche in einer Nachricht
 *   werden beim Senden zu Leerzeichen (in gueltigem JSON kommen sie nur als Whitespace vor).
 * - Auto-Reconnect alle 2 s, bis net_disconnect() aufgerufen wird.
 * - Der Thread haelt eine Referenz auf die DLL (FreeLibraryAndExitThread), damit ein
 *   FreeLibrary durch Lua (lua_close) den Code nicht unter dem laufenden Thread entlaedt.
 */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "net.h"

#define MAX_QUEUE_BYTES (64u * 1024u * 1024u)   /* je Richtung */
#define MAX_LINE        (16u * 1024u * 1024u)
#define RETRY_MS        2000

typedef struct msg { struct msg *next; size_t len; char data[1]; } msg;
typedef struct { msg *head, *tail; size_t bytes, count; } queue;

static CRITICAL_SECTION g_lock;
static volatile LONG g_inited = 0;
static queue g_in, g_out;
static char g_host[256];
static int g_port;
static volatile LONG g_status = NET_IDLE;
static volatile LONG g_want = 0;        /* 1 = verbunden sein wollen */
static volatile LONG g_generation = 0;  /* erhoeht bei neuem Ziel -> Thread verbindet neu */
static HANDLE g_thread = NULL;
static HANDLE g_wake = NULL;            /* Event: neue Ausgangsdaten / Zielwechsel */
static char g_err[256];
static char *g_hello = NULL;            /* wird bei jedem (Re-)Connect zuerst gesendet (inkl. '\n') */
static size_t g_hello_len = 0;
static volatile LONG g_connects = 0;    /* Anzahl erfolgreicher Verbindungen (Reconnect-Erkennung in Lua) */

static void set_err(const char *fmt, int code)
{
    EnterCriticalSection(&g_lock);
    snprintf(g_err, sizeof(g_err), fmt, code);
    LeaveCriticalSection(&g_lock);
}

static int q_push(queue *q, const char *data, size_t len)
{
    msg *m;
    if (q->bytes + len > MAX_QUEUE_BYTES) return 0;
    m = (msg *)malloc(sizeof(msg) + len);
    if (!m) return 0;
    m->next = NULL; m->len = len;
    memcpy(m->data, data, len); m->data[len] = '\0';
    if (q->tail) q->tail->next = m; else q->head = m;
    q->tail = m; q->bytes += len; q->count++;
    return 1;
}

static msg *q_pop(queue *q)
{
    msg *m = q->head;
    if (!m) return NULL;
    q->head = m->next;
    if (!q->head) q->tail = NULL;
    q->bytes -= m->len; q->count--;
    return m;
}

static void q_clear(queue *q)
{
    msg *m;
    while ((m = q_pop(q)) != NULL) free(m);
}

void net_init(void)
{
    if (InterlockedCompareExchange(&g_inited, 1, 0) == 0) {
        WSADATA w;
        InitializeCriticalSection(&g_lock);
        g_wake = CreateEventW(NULL, FALSE, FALSE, NULL);
        WSAStartup(MAKEWORD(2, 2), &w);
    }
}

static SOCKET do_connect(const char *host, int port)
{
    struct addrinfo hints, *res = NULL, *ai;
    char portstr[16];
    SOCKET s = INVALID_SOCKET;
    int rc;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    snprintf(portstr, sizeof(portstr), "%d", port);
    rc = getaddrinfo(host, portstr, &hints, &res);
    if (rc != 0) { set_err("getaddrinfo Fehler %d", rc); return INVALID_SOCKET; }
    for (ai = res; ai; ai = ai->ai_next) {
        u_long nb = 1;
        fd_set wf, ef;
        struct timeval tv = {5, 0};
        s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s == INVALID_SOCKET) continue;
        ioctlsocket(s, FIONBIO, &nb);
        connect(s, ai->ai_addr, (int)ai->ai_addrlen);
        FD_ZERO(&wf); FD_SET(s, &wf); FD_ZERO(&ef); FD_SET(s, &ef);
        if (select(0, NULL, &wf, &ef, &tv) == 1 && FD_ISSET(s, &wf)) {
            int one = 1;
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof(one));
            break;
        }
        set_err("connect fehlgeschlagen (WSA %d)", WSAGetLastError());
        closesocket(s); s = INVALID_SOCKET;
    }
    freeaddrinfo(res);
    return s;
}

/* Sendet alles aus der Ausgangs-Queue; 0 bei Verbindungsfehler. */
static int flush_out(SOCKET s, msg **cur, size_t *off)
{
    for (;;) {
        int n;
        if (!*cur) {
            EnterCriticalSection(&g_lock);
            *cur = q_pop(&g_out);
            LeaveCriticalSection(&g_lock);
            *off = 0;
            if (!*cur) return 1;
        }
        n = send(s, (*cur)->data + *off, (int)((*cur)->len - *off), 0);
        if (n == SOCKET_ERROR) {
            int e = WSAGetLastError();
            if (e == WSAEWOULDBLOCK) return 1;
            set_err("send Fehler (WSA %d)", e);
            return 0;
        }
        *off += (size_t)n;
        if (*off == (*cur)->len) { free(*cur); *cur = NULL; }
    }
}

static DWORD WINAPI worker(LPVOID self_module)
{
    char *line = (char *)malloc(65536);
    size_t cap = 65536, used = 0;
    for (;;) {
        SOCKET s;
        LONG gen;
        char host[256]; int port;
        msg *cur = NULL; size_t off = 0;
        if (!g_want) { InterlockedExchange(&g_status, NET_IDLE); WaitForSingleObject(g_wake, 500); continue; }
        EnterCriticalSection(&g_lock);
        memcpy(host, g_host, sizeof(host)); port = g_port; gen = g_generation;
        LeaveCriticalSection(&g_lock);
        InterlockedExchange(&g_status, NET_CONNECTING);
        s = do_connect(host, port);
        if (s == INVALID_SOCKET) {
            InterlockedExchange(&g_status, NET_RETRY_WAIT);
            WaitForSingleObject(g_wake, RETRY_MS);
            continue;
        }
        /* Hello zuerst, damit der Server den Handshake vor allen wartenden Nachrichten sieht */
        {
            int ok = 1;
            EnterCriticalSection(&g_lock);
            if (g_hello) {
                size_t sent = 0;
                while (sent < g_hello_len) {
                    int n = send(s, g_hello + sent, (int)(g_hello_len - sent), 0);
                    if (n == SOCKET_ERROR) {
                        if (WSAGetLastError() == WSAEWOULDBLOCK) { Sleep(1); continue; }
                        ok = 0; break;
                    }
                    sent += (size_t)n;
                }
            }
            LeaveCriticalSection(&g_lock);
            if (!ok) {
                set_err("hello senden fehlgeschlagen (WSA %d)", WSAGetLastError());
                closesocket(s);
                InterlockedExchange(&g_status, NET_RETRY_WAIT);
                WaitForSingleObject(g_wake, RETRY_MS);
                continue;
            }
        }
        InterlockedIncrement(&g_connects);
        InterlockedExchange(&g_status, NET_CONNECTED);
        used = 0;
        while (g_want && gen == g_generation) {
            fd_set rf; struct timeval tv = {0, 20000};
            int r;
            if (!flush_out(s, &cur, &off)) break;
            FD_ZERO(&rf); FD_SET(s, &rf);
            r = select(0, &rf, NULL, NULL, &tv);
            if (r == SOCKET_ERROR) { set_err("select Fehler (WSA %d)", WSAGetLastError()); break; }
            if (r == 1) {
                int n;
                if (cap - used < 4096) {
                    char *nl;
                    if (cap >= MAX_LINE) { set_err("Zeile zu lang (> %d Byte)", (int)MAX_LINE); break; }
                    nl = (char *)realloc(line, cap * 2);
                    if (!nl) break;
                    line = nl; cap *= 2;
                }
                n = recv(s, line + used, (int)(cap - used), 0);
                if (n == 0) { set_err("Server hat Verbindung geschlossen%.0d", 0); break; }
                if (n == SOCKET_ERROR) {
                    int e = WSAGetLastError();
                    if (e == WSAEWOULDBLOCK) continue;
                    set_err("recv Fehler (WSA %d)", e); break;
                }
                used += (size_t)n;
                /* Komplette Zeilen in die Eingangs-Queue */
                {
                    size_t start = 0, i;
                    for (i = 0; i < used; i++) {
                        if (line[i] == '\n') {
                            size_t len = i - start;
                            if (len && line[start + len - 1] == '\r') len--;
                            if (len) {
                                EnterCriticalSection(&g_lock);
                                q_push(&g_in, line + start, len); /* bei voller Queue verworfen */
                                LeaveCriticalSection(&g_lock);
                            }
                            start = i + 1;
                        }
                    }
                    if (start) { memmove(line, line + start, used - start); used -= start; }
                }
            }
        }
        if (cur) free(cur);
        closesocket(s);
        InterlockedExchange(&g_status, g_want ? NET_RETRY_WAIT : NET_IDLE);
        if (g_want && gen == g_generation) WaitForSingleObject(g_wake, RETRY_MS);
    }
    /* nicht erreicht */
    free(line);
    FreeLibraryAndExitThread((HMODULE)self_module, 0);
    return 0;
}

static void ensure_thread(void)
{
    if (!g_thread) {
        HMODULE self = NULL;
        /* Referenz auf die eigene DLL halten (siehe Kopfkommentar) */
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, (LPCWSTR)(void *)&ensure_thread, &self);
        g_thread = CreateThread(NULL, 0, worker, self, 0, NULL);
    }
}

int net_connect(const char *host, size_t hostlen, int port)
{
    net_init();
    if (hostlen == 0 || hostlen >= sizeof(g_host) || port <= 0 || port > 65535) return 0;
    EnterCriticalSection(&g_lock);
    /* Gleiches Ziel und schon aktiv -> nichts tun (Lua-Module laufen pro Environment neu,
       die Verbindung der DLL soll das ueberleben) */
    if (g_want && g_port == port && strlen(g_host) == hostlen && memcmp(g_host, host, hostlen) == 0) {
        LeaveCriticalSection(&g_lock);
        return 1;
    }
    memcpy(g_host, host, hostlen); g_host[hostlen] = '\0';
    g_port = port;
    g_err[0] = '\0';
    InterlockedIncrement(&g_generation);
    InterlockedExchange(&g_want, 1);
    ensure_thread();
    LeaveCriticalSection(&g_lock);
    SetEvent(g_wake);
    return 1;
}

void net_disconnect(void)
{
    net_init();
    InterlockedExchange(&g_want, 0);
    InterlockedIncrement(&g_generation);
    EnterCriticalSection(&g_lock);
    q_clear(&g_out);
    LeaveCriticalSection(&g_lock);
    SetEvent(g_wake);
}

int net_send(const char *data, size_t len)
{
    int ok;
    char *tmp;
    size_t i;
    net_init();
    tmp = (char *)malloc(len + 1);
    if (!tmp) return 0;
    for (i = 0; i < len; i++) tmp[i] = (data[i] == '\n' || data[i] == '\r') ? ' ' : data[i];
    tmp[len] = '\n';
    EnterCriticalSection(&g_lock);
    ok = q_push(&g_out, tmp, len + 1);
    LeaveCriticalSection(&g_lock);
    free(tmp);
    if (ok) SetEvent(g_wake);
    return ok;
}

char *net_poll(size_t *len)
{
    msg *m;
    net_init();
    EnterCriticalSection(&g_lock);
    m = q_pop(&g_in);
    LeaveCriticalSection(&g_lock);
    if (!m) return NULL;
    *len = m->len;
    /* data liegt im selben Block; Aufrufer gibt ueber net_free(data) frei */
    return m->data;
}

void net_free(char *p)
{
    if (p) free((char *)p - offsetof(msg, data));
}

int net_status(void) { return (int)g_status; }

int net_connect_count(void) { return (int)g_connects; }

int net_set_hello(const char *data, size_t len)
{
    char *h;
    size_t i;
    net_init();
    h = (char *)malloc(len + 1);
    if (!h) return 0;
    for (i = 0; i < len; i++) h[i] = (data[i] == '\n' || data[i] == '\r') ? ' ' : data[i];
    h[len] = '\n';
    EnterCriticalSection(&g_lock);
    free(g_hello);
    g_hello = len ? h : NULL;
    g_hello_len = len ? len + 1 : 0;
    LeaveCriticalSection(&g_lock);
    if (!len) free(h);
    return 1;
}

size_t net_pending_in(void)
{
    size_t n; net_init();
    EnterCriticalSection(&g_lock); n = g_in.count; LeaveCriticalSection(&g_lock);
    return n;
}

size_t net_pending_out(void)
{
    size_t n; net_init();
    EnterCriticalSection(&g_lock); n = g_out.count; LeaveCriticalSection(&g_lock);
    return n;
}

void net_last_error(char *buf, size_t cap)
{
    net_init();
    EnterCriticalSection(&g_lock);
    snprintf(buf, cap, "%s", g_err);
    LeaveCriticalSection(&g_lock);
}
