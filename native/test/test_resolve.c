/* Prueft die Signatursuche gegen eine echte PlanetCoaster2.exe, ohne sie auszufuehren
   (Image wird nur als Ressource gemappt). Aufruf: test_resolve.exe "<Pfad>\PlanetCoaster2.exe" */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include "../frontier_lua.h"

int main(int argc, char **argv)
{
    HMODULE h;
    const unsigned char *base;
    flua_resolved r;
    DWORD t0;
    if (argc < 2) { printf("usage: test_resolve <PlanetCoaster2.exe>\n"); return 2; }
    h = LoadLibraryExA(argv[1], NULL, LOAD_LIBRARY_AS_IMAGE_RESOURCE | LOAD_LIBRARY_AS_DATAFILE);
    if (!h) { printf("LoadLibraryEx fehlgeschlagen: %lu\n", GetLastError()); return 1; }
    base = (const unsigned char *)((ULONG_PTR)h & ~(ULONG_PTR)3);
    t0 = GetTickCount();
    flua_resolve_image(base, &r);
    printf("%s\n(Scan %lu ms)\n", r.info, GetTickCount() - t0);
    return r.newlstr ? 0 : 1;
}
