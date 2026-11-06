/* Nicht-blockierender TCP-Client (newline-delimited JSON) fuer PC2MP. Thread-sicher. */
#ifndef PC2MP_NET_H
#define PC2MP_NET_H
#include <stddef.h>

enum { NET_IDLE = 0, NET_CONNECTING = 1, NET_CONNECTED = 2, NET_RETRY_WAIT = 3 };

void   net_init(void);
int    net_connect(const char *host, size_t hostlen, int port);  /* startet/zielt Worker-Thread um */
void   net_disconnect(void);                                     /* trennt, kein Auto-Reconnect mehr */
int    net_send(const char *msg, size_t len);                    /* 1 = eingereiht, 0 = Queue voll */
/* Naechste empfangene Nachricht (ohne '\n'); Aufrufer gibt mit net_free frei. NULL = keine. */
char  *net_poll(size_t *len);
void   net_free(char *p);
int    net_status(void);
int    net_connect_count(void);                                  /* +1 je erfolgreicher Verbindung */
/* Nachricht, die bei jedem (Re-)Connect als erste gesendet wird (leer = keine). */
int    net_set_hello(const char *msg, size_t len);
size_t net_pending_in(void);
size_t net_pending_out(void);
void   net_last_error(char *buf, size_t cap);
#endif
