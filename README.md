# BlechWiki für iPhone, iPad und Mac

iOS-App, die zeigt, in welchen Bläserheften ein Stück steht und ob das Heft im eigenen Notenschrank liegt. Die Daten kommen über die REST-Schnittstelle von [blechwiki.de](https://www.blechwiki.de/extras/). Gesucht wird lokal auf dem Gerät, auch ohne Internet.

**[Funktionen und Screenshots →](docs/FUNKTIONEN.md)** · [API-Analyse und Architektur](docs/ARCHITEKTUR.md) · [Datenschutzerklärung](docs/DATENSCHUTZ.md) · [Impressum](docs/IMPRESSUM.md)

Fehler und Wünsche bitte als [Issue](https://github.com/lasseeggers/BlechWiki-iOS/issues) melden.

Die Funktionsübersicht zeigt auch die Android-App. Deren Code ist nicht in diesem Repo.

## Aufbau

Native SwiftUI-App, ab iOS 17. Auf dem Mac läuft sie als Mac-Catalyst-App (ab macOS 14).

| Teil | Inhalt |
|---|---|
| `ios/BlechWikiCore` | Swift-Package mit der Logik: REST-Client, SQLite mit FTS4, Abgleich über Änderungszähler, Cache der Suchergebnisse, Inventar-Code. Läuft auch auf macOS, Tests ohne Simulator |
| `ios/BetterBlechWiki` | SwiftUI-Oberfläche: Suche, Suchergebnisse, Buchansicht, Inventar, Gesangbuch |
| `ios/ShareExtension` | Teilen-Ziel „Inventar übernehmen“ für Nachrichten mit Inventar-Code |

## Bauen und testen

```sh
cd ios/BlechWikiCore && swift test                 # Tests der Logik, ohne Netz
BLECHWIKI_LIVE=1 swift test --filter LiveTests     # wenige Requests gegen die echten Server
ios/scripts/run-on-device.sh                       # bauen, signieren, aufs angeschlossene iPhone
```

Die Live-Tests schicken eine Handvoll Requests an den privat betriebenen Server. Bitte nur gezielt ausführen.

Zeigt `xcode-select` auf die Command Line Tools statt auf Xcode, brauchen die Befehle `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (das Skript setzt es selbst).

Fürs iPhone muss in Xcode › Einstellungen › Accounts ein Apple-Account angemeldet sein. Team, Bundle-ID und App Group im Projekt gehören zum veröffentlichten Build, für einen eigenen Build alle drei in Xcode auf das eigene Team ändern und die Bundle-ID dem Skript per `BUNDLE_ID=…` mitgeben. Mit einem kostenlosen Account (Personal Team) lassen sich nach meinem Stand keine App Groups anlegen. Dann die App Group aus beiden Zielen entfernen und das Ziel ShareExtension aus „Embed Foundation Extensions“ nehmen. Die App läuft auch ohne, nur „Inventar übernehmen“ im Teilen-Dialog fehlt. Mit kostenlosem Account läuft die App 7 Tage und muss danach neu installiert werden. Beim ersten Start am iPhone: *Einstellungen › Datenschutz & Sicherheit › Entwicklermodus* einschalten und unter *Allgemein › VPN & Geräteverwaltung* dem Entwickler vertrauen.

Auf dem Mac in Xcode als Ziel „My Mac (Mac Catalyst)“ wählen und mit ⌘R starten. Auch dafür muss das Team auf das eigene geändert werden.

## Eigenheiten

- Kein Hintergrund-Abgleich. iOS lässt Apps im Hintergrund kaum laufen, deshalb prüft die App die Datenversion beim Öffnen (höchstens alle 24 h) und lädt Inventar-Bücher, solange sie offen ist. Der monatliche Vollabgleich läuft nur im WLAN.
- Ein geteilter Inventar-Code wird direkt im Teilen-Dialog übernommen (Share Extension „Inventar übernehmen“), nicht in der App. Eine Extension darf die App nicht öffnen. Bücherverzeichnis und Einstellungen liegen dafür in der App Group `group.blechwiki.eggers.media`. Den Inhalt der Bücher lädt die App beim nächsten Öffnen. Läuft sie gerade (iPad in Split View), meldet die Extension die Übernahme per Darwin-Notification, und die App lädt sofort.
- Inventar-Codes sind identisch mit der Android-App. Der Test `gleicheCodesWieAndroid` prüft das gegen Codes aus der Android-Version.

## Lizenz

[MIT](LICENSE)
