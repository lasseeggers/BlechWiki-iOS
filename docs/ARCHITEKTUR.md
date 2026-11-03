# BlechWiki: API-Analyse und Architektur

Stand: 03.11.2026. Grundlage sind die Beschreibung des Betreibers Dieter Kipp und Testaufrufe gegen `https://pcportal.ddns.net/RestBlechWiki1/api/`. Diese Adresse hat Dieter Kipp am 03.11.2026 für die App eingerichtet. Die frühere Adresse `RestBlechWiki` lieferte zu diesem Zeitpunkt dieselben Daten. Bis Version 0.6.1 nutzte die App die SOAP-Schnittstelle `LiteraService`. Der Betreiber hat den Umstieg auf REST empfohlen, SOAP läuft aus.

## 1. Was die API kann

JSON über HTTPS (ASP.NET Web API auf IIS). Die Schnittstelle bietet nur GET. Kein Login, kein gzip, kein ETag, Antwortzeiten 0,1 bis 0,6 s. Eine automatisch erzeugte Liste der Routen ohne Beschreibungen steht unter `/RestBlechWiki1/Help`. Dieter Kipp schreibt die Adresse mit `http://`, die App nutzt HTTPS, weil iOS unverschlüsseltes HTTP blockiert.

### Stammdaten mit Änderungszähler

`Version?Tabelle=<Tabelle>&counter=<N>`. Jeder Datensatz trägt `change` (`new`, `update` oder `delete`) und `changecounter`, den Zähler seiner letzten Änderung. Datensätze, die gemeinsam geändert wurden, haben denselben Zähler.

- `counter=0` liefert die ganze Tabelle ohne gelöschte Einträge.
- `counter=N` liefert nur Einträge mit höherem Zähler, gelöschte eingeschlossen. Ohne Änderungen kommt `[]` (2 Byte).

| Tabelle | Schlüssel | Felder | Umfang bei `counter=0` |
|---|---|---|---|
| `Titel` | `ix` | `titel`, `titelohneKomma` | 9.915 Titel ohne Doppel (aus ca. 37.000 Einträgen), 1,2 MB. Nur `new` und `delete`. |
| `Buch` | `buchId`, Zahl als Text | `buchkurz`, `buch`, `untertitel`, `erscheinjahr`, `herausgeber`, `herausgvorname`, `verlag`, `verlagsnummer` | 755 Bücher, 257 KB |
| `Komponist` | `id`, Zahl als Text | `kurz`, `komponist` (mit Lebensdaten in Klammern), `friendlyKomponistName` | 2.477 Einträge zu 2.423 ids, 381 KB |

Zählerstand am 01.11.2026: Titel 69, Buch 122, Komponist 78.

### EG-Lieder

`EG` liefert 2.290 Einträge, einen je Lied und EG-Teil: `ix`, `ixUr`, `nr`, `nr2`, `lied`, `anlass`, `egTeil` (282 KB). Die Tabelle ist statisch und hat keinen Änderungszähler. Die 1.255 verschiedenen `ix` stimmen mit der SOAP-Methode `GetEGLieder2` überein.

- `ix` steht für das Lied, `ixUr` für die **Melodie**. 110 Melodien gehören zu mehreren Liedtexten.
- `nr2` ist eine Unternummer wie bei EG 676.2, z. B. EG 577 mit `nr2` 1 und 2 im Anhang Österreich (vom Betreiber am 03.11.2026 bestätigt). Die App nutzt sie nicht.
- Teile: `Stamm`, die 13 Anhänge der Landeskirchen und `Add`. Oldenburg heißt hier `Ol`, in `EG?anhaenge=true` `OL`. Die App vergleicht die Kürzel ohne Groß- und Kleinschreibung.
- `Add` („Ergänzungen“): 11 Lieder, die unter einem anderen, meist englischen Titel bekannt sind und mit deutschem Text im EG stehen, z. B. „Go, tell it on the mountain“ (`ix` 1317) zu „Komm, sag es allen weiter“ (EG 225, `ix` 792). `ixUr` ist der `ix` des deutschen Lieds, die Fundstellen kommen daher über `EG/{ixUr}`. Die Nummern 601 bis 611 sind keine EG-Nummern. Die App zeigt statt einer Nummer „im EG als „Komm, sag es allen weiter“, EG 225“, die Nummernsuche findet diese Lieder nicht, und im Gesangbuch und in der Auswahl der Landeskirche erscheinen sie nicht.

### Fundstellen (wo steht ein Stück?)

In der App heißt die Ansicht dazu „Suchergebnisse“. Im Code und in dieser Doku bleibt „Fundstelle“ der Begriff für eine Zeile aus diesen Endpunkten.

| Endpunkt | Schlüssel | Beispiel |
|---|---|---|
| `Titel/{ix}` | `ix` aus `Titel` | 10374 „Alle Augen warten auf dich, Herre“ → 2 Fundstellen |
| `EG/{ixUr}` | Melodie | EG 316 (`ixUr` 859) → 218 Fundstellen, auch unter anderem Liedtext |
| `Buch/{buchId}` | `buchId` | 4035 „Bläsermusik 2025 - Württemberg“ → 76 Stücke, 17 KB |
| `Komponist/{id}` | `id` aus `Komponist` | 2000 „Kreuter, Walter“ |

Alle liefern dieselbe Zeilenstruktur: `buch, nr, titel, zus, komponist, besetzung, vorzeichen, titelZ, buchId, quellekurz`. Untertitel und Cover fehlen, die App ergänzt sie aus den Stammdaten. `titelZ` wird beim Neueinlesen der Datenbank neu vergeben und taugt nicht als Schlüssel. Fundstellen identifizieren wir weiter über `(buchId, nr, titel, zus)`.

Die Beschreibung des Betreibers nennt für `EG/{…}` den `ix`. Sein Beispiel und unsere Tests zeigen, dass die Melodie (`ixUr`) gemeint ist.

### Verhalten und Eigenheiten

- Unbekannte IDs liefern HTTP 500 mit `{"Message":"Fehler"}`.
- Zwei Titel kommen doppelt vor und unterscheiden sich nur durch ein Leerzeichen am Ende („Kanon“, ix 4292 und 8358). Sie haben getrennte Fundstellen, die App führt beide.
- Komponisten: Schreibvarianten stehen als eigene Zeilen mit derselben `id`, erkennbar an `( alias … )` im Feld `komponist`. Die App speichert nur den Haupteintrag. Lebensdaten stehen in Formen wie `(1685-1750)`, `(1954- )`, `( - )` oder `(um 1600-nach 1650)` am Ende des Namens.
- Bücher: SOAP lieferte 786. Im neuen Datenmodell fehlen 13 Pseudo-Bücher für die EG-Anhänge („EG NB“ usw.) und 18 Einträge „Einzelaus…“.
- `EG?anhaenge=true` liefert die Teile des EG als `EGTeilkurz` und `EGTeil`, z. B. `NB` = Niedersachsen/Bremen, `M` = Mecklenburg, dazu `Stamm` und `Add`. Die App lädt die Liste beim Vollabgleich. Ist sie nicht lesbar oder leer, nimmt sie eine eingebaute Liste mit Stand 03.11.2026, damit der Abgleich nicht scheitert.
- `Titel?search=` liefert höchstens 100 Fundstellen ohne `buchId` und wird nicht genutzt.
- Cover-Bilder: `https://teddymuetze.ddns.net/Bilder/BilderBuch/<buchkurz>.jpg` im Original (ca. 1000 × 1444 px, ca. 200 KB), laut Betreiber zusätzlich unter `mini60/`, `mini120/` und `mini240/`. Die App nutzt `mini120` in Listen und das Original im Buchkopf, mit Rückfall auf `mini60` (`CoverUrls`).
- Buch-Stammdaten enthalten Herausgeber, Verlag, Bestellnummer und Jahr. Seitenzahlen gibt es nicht, nur die Nummer im Heft.
- Der Server ist ein privat betriebener DDNS-Host. Die App muss sparsam sein: keine Vollabzüge aller Fundstellen (755 Buchaufrufe).

## 2. Konsequenz für Suche und Caching

Kernidee: **Tippen kostet keine Anfrage.** Alle Stammdaten (Titel, EG, Bücher, Komponisten) liegen nach dem ersten Start lokal in einer FTS-Datenbank. Eine Netzwerkanfrage gibt es erst, wenn der Nutzer einen Treffer öffnet, und auch dann nur einmal pro Titel.

### Stufe 1: Initial-Sync (einmalig, 4 Requests, ~2,1 MB)

`Version?…&counter=0` für Titel, Bücher und Komponisten, dazu `EG` → Room bzw. SQLite. Läuft beim ersten Start mit Fortschrittsanzeige. Danach holt die App nur noch Änderungen, siehe [Aktualisierung](#aktualisierung).

### Stufe 2: Lokale Suche

Room-FTS4-Tabelle über normalisierte Texte (Kleinschreibung, ä→a, ß→ss, æ→ae, ø→o, Ligaturen wie ﬁ→fi, Satzzeichen entfernt, Whitespace getrimmt). Eine Anfrage nutzt höchstens 16 verschiedene Wörter, sonst wird der FTS-Ausdruck für SQLite zu groß. Damit funktioniert, was die API nicht kann:

- mehrere Wörter in beliebiger Reihenfolge, Präfixsuche pro Wort („lob herr mächt“)
- EG-Nummer direkt: „316“, „EG 316“, „EG316“ oder „EG-316“ (auch mit Anführungszeichen oder Punkt) → Lied, abhängig von der gewählten Landeskirche auch Anhangsnummern
- Bücher und Komponisten in derselben Ergebnisliste, gruppiert
- Ergebnisse ohne Netz und ohne Latenz

### Stufe 3: Fundstellen lazy laden, dauerhaft speichern

- Titel öffnen → `Titel/{ix}`. Ist der Titel ein EG-Lied, stattdessen `EG/{ixUr}`, weil das Titelvarianten mit abdeckt.
- Die EG-Abfrage liefert alle Sätze zur Melodie, auch unter anderem Text. Für Bläser ist das gewollt, die Detailansicht weist darauf hin.
- In der Suche erscheinen Titel, die einem EG-Liednamen entsprechen (1.136 von 1.255), nur als EG-Treffer.
- Ergebnis in Room mit `fetchedAt`. Beim nächsten Öffnen sofort aus dem Cache anzeigen (stale-while-revalidate), Neuladen nur, wenn der Eintrag älter als 30 Tage ist oder neue Titel hinzugekommen sind (Änderungszähler der Titel).
- Parallele Anfragen zum selben Schlüssel werden zusammengelegt (single flight).

### Stufe 4: Inventar

Im Inventar stehen die Bücher aus dem Notenschrank des Chors. Eingetragen werden sie in einer Auswahlliste oder per Lesezeichen an jeder Buchkarte in den Suchergebnissen. Für jedes Buch im Inventar lädt ein WorkManager-Job `Buch/{buchId}` (ca. 20 bis 40 KB pro Buch, nacheinander). Danach:

- zeigt die Trefferliste der Suche direkt „Im Inventar: Bläserheft 2026 Bayern Nr. 10“, ohne Server-Anfrage
- stehen Bücher aus dem Inventar in jeder Liste von Suchergebnissen oben, mit Filter „Inventar“

Die Suche selbst bleibt ohne Filter. Gefiltert wird erst auf der Ergebnisseite.

Die Auswahlliste schlägt Bücher passend zur Landeskirche vor. Grundlage sind Wortanfänge in Titel, Untertitel, Herausgeber und Verlag (`RegionKeywords`). Das trifft etwa 120 der 755 Bücher, vor allem die Jahreshefte. Es ist eine Hilfe zum schnellen Finden, keine verlässliche Zuordnung.

Einschränkung: „Im Inventar“ vergleicht den normalisierten Titel. Sätze, die im Heft unter einem anderen Liedtext zur selben Melodie stehen, erkennt die Suche nicht. Die Suchergebnisse eines EG-Lieds zeigen sie trotzdem.

#### Inventar teilen

Damit nicht jedes Chormitglied den Notenschrank selbst durchgeht, lässt sich das Inventar als Code weitergeben, ohne Server: `BBW-SCCC-XXXX-XXXX-…` (`InventoryCode`).

- je Buch 4 Zeichen Crockford-Base32 mit den ersten 20 Bit von SHA-256 über Startwert und Buch-ID (`buchId`). Der Empfänger rechnet die Hashes über sein eigenes Verzeichnis nach, die IDs selbst stehen nicht im Code.
- `S` ist der Startwert (0 bis 31). Der Absender nimmt den kleinsten, bei dem keines seiner Bücher mit einem anderen Buch kollidiert. Bei rund 800 Büchern ist mit 20 Bit etwa ein kollidierendes Paar zu erwarten.
- `CCC` ist eine 15-Bit-Prüfsumme über die sortierten IDs. Sie erkennt veränderte Codes und löst Kollisionen auf, die beim Empfänger durch neue Bücher entstehen.
- Der Code wird per Muster in beliebigem Text gefunden. Begleittext im Messenger stört nicht. Zwischen den Gruppen sind Bindestrich, Halbgeviert-, Geviert- und Minuszeichen erlaubt, auch Leerraum, Zeilenumbrüche und Zitatzeichen „>“ aus weitergeleiteten Mails. Ein Code ganz ohne Striche gilt nur, wenn er vollständig aufgeht, damit Fließtext wie „BBW will dich“ nicht als Code durchgeht.
- Wege in die App: „Teilen“ einer Nachricht an die App (Ziel „Inventar übernehmen“) oder im Inventar über das Menü „Inventar-Code einfügen“. Auf Android belegt der Dialog einen Code aus der Zwischenablage vor. Auf iOS gibt es dafür den Knopf „Einsetzen“, weil iOS beim Lesen der Zwischenablage sonst jedes Mal nachfragt.
- Enthält der Code Bücher, die das lokale Verzeichnis nicht kennt, prüft die App sofort die Datenversion (Android `SyncScheduler.checkNow`, iOS `SyncCoordinator.checkCatalogNow`). Der Dialog wertet danach neu aus. Ist danach immer noch kein einziges Buch bekannt, gilt der Code als verändert.
- **Kompatibilität:** Ab Version 1.0 müssen alle künftigen Versionen Codes mit dem Präfix `BBW` lesen können, auf jeder Plattform. Ein geändertes Format bekommt ein neues Präfix, `BBW` bleibt lesbar. Mit dem Umstieg auf REST in 0.7.0 haben sich die Buch-IDs geändert (vorher der Kurzname, jetzt die Zahl). Inventar und Codes aus 0.6.1 und älter gelten nicht mehr, vor 1.0 war das in Ordnung.

Eine eigene Dateiendung wurde verworfen: Android wählt die App über den MIME-Typ, den der Messenger mitgibt, und der ist bei unbekannten Endungen meist `application/octet-stream`.

Landeskirche und Inventar liegen in DataStore (iOS: UserDefaults der App Group), nicht in Room bzw. SQLite. Die Datenbank ist ein reiner Cache und wird bei Schema-Änderungen verworfen. Ausnahme: Ändert sich nur die Normalisierung, baut eine Migration den Suchindex und `fundstellen.titleNorm` aus den lokalen Daten neu, ohne etwas neu zu laden (iOS Schema 3→4, Android Room 5→6).

### Aktualisierung

- Je Tabelle merkt sich die App den höchsten `changecounter` und fragt mit `counter=<Stand>`. Ohne Änderungen sind das drei Requests à 2 Byte.
- Titel und Bücher übernimmt die App Eintrag für Eintrag: neu, geändert oder gelöscht. Der Suchindex des Bereichs wird danach aus der lokalen Tabelle neu gebaut.
- Komponisten lädt die App bei jeder Änderung ganz neu (381 KB). Schreibvarianten haben dieselbe `id`, eine einzelne Änderung lässt sich nicht eindeutig einer Zeile zuordnen.
- Die EG-Lieder haben keinen Zähler. Sie kommen beim ersten Abgleich und beim Vollabgleich, den der WLAN-Job alle 30 Tage macht.
- Prüfung beim App-Start höchstens alle 24 h. Android hat zusätzlich einen WorkManager-Job, der wöchentlich im WLAN läuft. iOS hat keinen Hintergrund-Job, dort läuft der Vollabgleich beim Öffnen im WLAN.
- Zeilen, denen ein Pflichtfeld fehlt, überspringt die App. Der gemerkte Zähler rückt trotzdem bis zum höchsten `changecounter` der Antwort vor, auch wenn er zu einer übersprungenen Zeile gehört. Sonst käme ein einzelner fehlerhafter Eintrag bei jedem Abgleich wieder und hielte ihn auf. Als Fehler gilt eine Antwort nur, wenn eine ganze Tabelle leer oder ganz unlesbar zurückkommt oder sich in einer Liste der Änderungen nicht einmal ein Zähler lesen lässt. Dann bleibt der alte Stand.
- Inventar-Bücher, die nicht mehr im Verzeichnis stehen (vom Server gelöscht), lädt die App nicht. Der Server beantwortet unbekannte Buch-IDs mit HTTP 500.
- iOS liest über eine zweite, nur lesende SQLite-Verbindung. Ein laufender Abgleich, der den Suchindex schreibt, hält so keine Anzeige auf (WAL).
- Fundstellen: 30-Tage-TTL und Pull-to-refresh auf der Detailseite.

### Gesangbuch

- „Gesangbuch“ auf der Startseite listet Stammteil plus Anhang der gewählten Landeskirche nach Anlass, aus der lokalen Tabelle `eg_songs`. Der Stammteil ist sauber nach Anlass sortiert (569 Lieder, 38 Abschnitte). Im Anhang wechseln die Anlässe ständig (Niedersachsen/Bremen: 53 Wechsel bei 27 Anlässen). Anhangslieder stehen deshalb im Abschnitt ihres Anlasses hinter den Stammteil-Liedern (`HymnalSections`).

## 3. Technische Architektur

Kotlin, Jetpack Compose, Material 3, eine Activity, Unidirectional Data Flow (ViewModel → `StateFlow<UiState>`).

| Bereich | Wahl | Begründung |
|---|---|---|
| Netzwerk | OkHttp + JSON-Parser von kotlinx.serialization (ohne Compiler-Plugin) | 6 GET-Endpunkte mit flachen Zeilen. Eigene DTOs mit Mapping von Hand, weil die API leere Werte als `""` liefert und Zahlen teils als Text. |
| Persistenz | Room mit FTS4 | lokale Suche, Fundstellen-Cache, Favoriten |
| Einstellungen | DataStore | Landeskirche, Sync-Zeitpunkte, Datenversion |
| Hintergrund | WorkManager | Initial-Sync, Inventar-Download, Update-Check |
| DI | Hilt | Standard, gut testbar |
| Bilder | Coil mit Disk-Cache | Cover sind unveränderlich |
| Navigation | Navigation Compose (typsichere Routen) | |

### Module

```
:app                 Activity, Navigation, Theme, Hilt-Setup
:core:network        REST-Client, DTOs
:core:database       Room-Entities, DAOs, FTS, Normalisierung
:core:data           Repositories (Sync, Search, Fundstellen, Inventar), Mapping DTO → Domain
```

Die UI liegt in `:app`. Eigene Feature-Module lohnen sich erst, wenn deutlich mehr Screens dazukommen. `:core:network` ist ein reines Kotlin/JVM-Modul, die Tests laufen ohne Android.

### Datenmodell (Room)

```
titles(ix PK, title)
books(id PK, title, subtitle, year, editor, publisher, publisherNumber, coverUrl)
composers(id PK, name, born, died)
eg_songs(id PK auto, ix, ixUr, title, part, number, occasion)
eg_appendices(code PK, name)
search_index  (FTS4 über content; norm, label, detail, type, refKey, refNumber)
sync_state(id PK = 0, titleChangeCounter, bookChangeCounter, composerChangeCounter, checkedAtMillis, fullSyncAtMillis)
fundstellen(queryKey, position, bookId, bookTitle, bookSubtitle, number, title, titleNorm, …)  PK(queryKey, position)
fetch_state(queryKey PK, fetchedAtMillis, titleVersion)   queryKey = "title:<ix>" | "eg:<ixUr>" | "book:<id>" | "composer:<id>"
```

Auf iOS liegt dasselbe Schema in SQLite (`AppDatabase`).

### Datenfluss Suche → Ergebnis

```
Tastendruck ─► SearchViewModel ─► SearchRepository.search(q)  (Room FTS, kein Netz)
Treffer antippen ─► DetailViewModel ─► FundstellenRepository.observe(key)
                                         ├─ Room-Flow liefert Cache sofort
                                         └─ falls fehlend/veraltet: BlechWikiApi ─► Room upsert ─► Flow emittiert neu
```

## 4. Bedienung

- Startseite = Suchfeld, darunter Inventar, Gesangbuch, Landeskirche und App-Informationen.
- Ergebnisse erscheinen beim Tippen, gruppiert: EG-Lied, Titel, Buch, Komponist.
- Detailseite „Suchergebnisse“: Fundstellen gruppiert nach Buch, eigene Bücher oben und markiert, Chips für Besetzung (2+2, 3+3 …) und für „nur Inventar“. Das Vorzeichen steht an jeder Fundstelle.
- Offline-Hinweis nur dann, wenn eine Fundstelle wirklich nicht im Cache ist.
- Die Landeskirche wählt man auf der Startseite. Bis dahin zeigt das Gesangbuch nur den Stammteil.
- iOS auf iPad, Mac (Mac Catalyst) und aufgeklapptem iPhone Duo: Suche und Startseite links, die gewählte Seite rechts (`NavigationSplitView`). Auf schmalen Bildschirmen klappt das zum selben Stapel zusammen wie auf dem iPhone. Listen rechts werden ab 720 pt Spaltenbreite mittig begrenzt.
- Nur auf dem Mac: Jeder Befehl steht auch in der Menüleiste („Gehe zu“, „Inventar“, „Aktualisieren“ unter „Darstellung“, Impressum und Datenschutz unter „Hilfe“), die Seiten melden ihre Befehle per `focusedSceneValue`. ⌘, öffnet ein Einstellungsfenster mit der Landeskirche. Die Besetzung wählt man im Aufklappmenü statt in einer seitlich scrollenden Chip-Reihe, Buchzeilen haben ein Kontextmenü. Catalyst zeigt `.principal` in der Toolbar nicht, Unterzeilen stehen dort in der Liste. Überschriften in Inventar und Gesangbuch scrollen mit, statt oben stehen zu bleiben, weil ihr Hintergrund unter Catalyst nach dem Zurückscrollen über dem Listenanfang liegen blieb. Den aktuellen Anlass im Gesangbuch zeigt dort der Anlass-Knopf in der Toolbar. Die Menübefehle erscheinen auch auf dem iPad mit Tastatur.
- Android ab 600 dp Fensterbreite (aufgeklapptes Foldable, Tablet, Handy quer) genauso: Suche links, Seite rechts, Seite höchstens 840 dp breit. Beide Formen teilen sich einen `NavHost`, beim Auf- und Zuklappen bleibt die geöffnete Seite stehen.

## 5. Offene Punkte

- Wünsche an den Betreiber, Stand 03.11.2026:
  - Erledigt: nur GET, feste Adresse mit Version (`RestBlechWiki1`), Endpunkt für die EG-Teile.
  - Zurückgestellt: gzip. Der Betreiber schaltet es ein, wenn Bedarf erkennbar ist.
  - Gestrichen: alle Zählerstände in einem Aufruf (spart nur zwei Anfragen mit je 2 Byte Antwort) und ein neuer Zähler für ein Buch, wenn sich seine Fundstellen ändern. Der Bestand ändert sich bis auf Korrekturen kaum, das Neuladen nach 30 Tagen reicht.
  - Offen: Lebensdaten und Schreibvarianten der Komponisten als eigene Felder, stabile IDs (`ix`, `ixUr`, Komponisten) in den Fundstellen, `ixUr` in der Titeltabelle und HTTP 404 bei unbekannter ID. Mit `ixUr` in den Fundstellen fiele die Einschränkung unter „Stufe 4“ weg.
  - Offen: Bleibt `RestBlechWiki` für bestehende Installationen erreichbar, und wie lange?
- Klären, ob ein Initial-Download von ~2,1 MB pro Installation für den Betreiber in Ordnung ist, oder ob wir ein vorgebautes Datenbank-Asset in die APK legen (`createFromAsset`) und nur Deltas laden. Letzteres entlastet den Server und macht die App ab der ersten Sekunde nutzbar. Ich würde das so machen.
