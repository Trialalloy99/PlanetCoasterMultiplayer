# Was wird synchronisiert? (Stand 2026-11-07, Branch trialalloy/props-settings)

Legende: ✔ im Spiel bestätigt · ◐ gebaut + offline getestet, Ingame-Test offen · ✘ nicht möglich (Grund)

## Bauen
| Was | Status | Wie |
|---|---|---|
| Szenerie setzen/verschieben/drehen/skalieren/löschen | ✔ | pc2mp.events/replay/sync |
| Farben (FlexiColour), Lichtfarbe | ✔ | pc2mp.props |
| Lichtmuster, Atmosphäre, Name | ◐ | pc2mp.props |
| Animierte Szenerie: Schleifentyp, Auslöser, Intervall, Dauer | ◐ | pc2mp.sequencer |
| Event-Ablauf-Steuerung: Programm (Spuren/Ereignisse/Gruppen), Auslöser, Showzeiten, Musik | ◐ | pc2mp.sequencer |
| Terrain | ✔ | pc2mp.worldedit |
| Wege: Form, Belag, Rand, Farben | ✔ (Form) / ◐ (Farben im Test) | pc2mp.worldedit |
| Weg-Extras (Bänke/Lampen am Weg) | ◐ | als Szenerie |
| Achterbahnen, Fahrgeschäfte, Schienenbahnen, Rutschen: Strecke, Stationen, Wagen/Züge, Farben, Muster, Modus/Sequenz, Musik — live nach jeder Änderung | ◐ (v.6 im Spiel: Datei-Export ging nicht → v.7 über das Spielstand-System) | pc2mp.rides |
| Pools (Form, alle Werkzeuge) / Pool-Objekte (Wellenmaschine usw.) | ◐ (v.6 im Spiel: nicht erfasst → v.7 Umriss-Abfrage) | pc2mp.pools / Szenerie |
| Läden/Toiletten/Unterhaltung als Gebäude | ◐ | als Szenerie (falls Bauteil) |

## Park-Einstellungen
| Was | Status |
|---|---|
| Park offen/zu, Parkname, Eintritt/Fast-Pass/Poolpass-Preis + Preismodus | ◐ (11/11 Setter im Spiel erfasst ✔) |
| Gäste-Obergrenze, Beleuchtung Start/Ende, Zonen-Icons, Kredit-Stufe | ◐ |
| Sandbox-/Welt-Einstellungen (Pausemenü) | ◐ |
| Werbung: Kampagne starten/beenden, Budget | ◐ |
| Alles reparieren (Vandalismus) | ◐ |

## Zeit / Wetter
| Was | Status |
|---|---|
| Pause, Geschwindigkeit | ✔ (im Testmodus erfasst + angewendet) |
| feste Sonne, feste Uhrzeit | ◐ (jetzt über park-API statt HUD) |
| Wetter erzwingen | ◐ (jetzt über weather-API) |
| natürlicher Wetterwechsel | ◐ wird per Abfrage erkannt + angezeigt (Sturm/Typ/Temperatur), Übertragung noch nicht |
| Park-Uhr (Tag + Uhrzeit) | ◐ Angleich über die Spielgeschwindigkeit (pc2mp.clock); RE: GetParkDay [Park+0x320], GetTimeOfDayActual [Park+0x328..] sind Ausgaben, keine sichere Setz-Stelle |

## Läden, Fahrgeschäft-Betrieb, Personal, Geld
| Was | Status |
|---|---|
| Laden offen/zu, Auto-Einstellen, Preise, Sortiment, Produktnamen, faire Preise, Zutaten, gleicher Preis | ◐ |
| Fahrgeschäft offen/zu, Ticketpreis + -art, Wartung, Abfahrtsintervall, Lade-/Zusammenlege-Regeln | ◐ |
| Pool offen/zu, Name | ◐ |
| Mitarbeiter entlassen, umbenennen, Gehalt, Arbeitsort, Zone | ◐ |
| Mitarbeiter einstellen | ✘ vorerst aus: GenerateRandomStaff per Code stürzt ab (Crash-Dumps, ID -1) |
| Kontostand (Kassenwart = kleinste Client-ID gleicht an) | ◐ |
| Defekte von Fahrgeschäften | ◐ |
| Schmutz/Vandalismus von Toiletten | ✘ keine Setz-API |

## Nicht synchronisiert
- **Gäste** und ihr Verhalten, Warteschlangen-Längen, Position der Züge auf der Strecke (laufende Simulation):
  die Gäste-KI ist nativer Code, aus Lua gibt es keine API für einzelne Gäste/Züge. Siehe findings/props-settings.md §14.
- Statistik nach Kategorien (Einnahmen/Ausgaben-Aufschlüsselung): nur der Kontostand.
