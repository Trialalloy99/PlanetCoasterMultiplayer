# Regeln für KI-Agenten (und Menschen) in diesem Repo

Zwei Claude-Agenten arbeiten parallel an diesem Projekt (Maxi und Trialalloy).
Es gibt keine direkte Verbindung zwischen ihnen, dieses Repo ist der einzige Kommunikationskanal.

## Zu Beginn jeder Sitzung
1. `git pull`
2. `docs/STATUS.md` lesen
3. Offene Issues und neue Kommentare lesen: `gh issue list` / `gh issue view <nr> --comments`
4. `docs/findings/` überfliegen, bevor du etwas erforschst, vielleicht ist es schon gelöst.

## Arbeit übernehmen
- Jede Aufgabe ist ein GitHub-Issue.
- Bevor du anfängst: Label setzen (`agent:maxi` bzw. `agent:trialalloy`) und kurz kommentieren
  „übernehme ich“. **Kein Issue bearbeiten, das schon ein anderes `agent:`-Label hat.**
- Fragen, Zwischenstände und Übergaben: als Kommentar ins Issue (`gh issue comment`).
- Fertig: Ergebnis kommentieren, Issue schließen, `docs/STATUS.md` aktualisieren.

## Wissen teilen
- Forschungsergebnisse → `docs/findings/<thema>.md` (Modul, Funktion, Parameter, Status
  „verifiziert im Code“ vs. „im Spiel getestet“).
- Architektur-Entscheidungen → `docs/architecture.md`.

## Git
- Kleine Commits. Feature-Branches `maxi/...` bzw. `trialalloy/...` + Pull Request für Code.
- Docs (`docs/`, `AGENTS.md`) dürfen direkt auf `main`, vorher `git pull --rebase`.

## Rechtliches / Sicherheit (wichtig, Repo ist ÖFFENTLICH)
- **Keinen dekompilierten Spielcode, keine OVLs oder Spieldateien committen.**
  `gamelua/` ist in `.gitignore`. Nur Erkenntnisse und kurze Ausschnitte (wenige Zeilen).
- Keine „Trainer/Cheat“-Downloads für PC2 von GitHub nutzen (häufig Malware).
