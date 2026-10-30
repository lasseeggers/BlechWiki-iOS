# BlechWiki Offline: API-Analyse und Architektur

Stand: 27.10.2026, Grundlage sind Testaufrufe gegen `https://pcportal.ddns.net/LiteraService/service1.asmx`.

## 1. Was die API kann

SOAP 1.1/1.2 (ASMX). Fast alle Methoden liefern ein serialisiertes .NET-DataSet (Inline-XSD + `diffgr:diffgram`). Kein JSON, kein gzip, keine IDs für Titel.

### Stammdaten (komplett abrufbar, gut cachebar)

| Methode | Parameter | Inhalt | Größe |
|---|---|---|---|
| `GetTitel` | `Suchstring` (leer = alle) | eindeutige Titel, nur Spalte `TITEL` | 10.111 Zeilen, ~1 MB |
| `GetEGLieder2` | – | alle EG-Lieder inkl. Landeskirchen-Anhänge: `Ix, IxUr, Lied, Teil, Nr, Anlass` | 2.974 Zeilen, ~600 KB |
| `GetEGLieder` | `LkA` (z. B. `NB`) | EG-Lieder eines Anhangs + Stammteil | ~140 KB |
| `GetEGLkAnhänge` | – | 14 Landeskirchen-Kürzel (`EGTeilkurz, EGTeil`) | 3 KB |
| `GetBücher` | – | 786 Bücher: `BuchId, Buch, Untertitel, Erscheinjahr, Herausgeber, VERLAG, Verlagsnummer, ImgUrl` | ~330 KB |
| `GetKomponisten` | – | 2.202 Komponisten: `Komponist, kurz, Geboren, Gestorben` | ~410 KB |
| `GetlastAutonummer` | – | letzte AutoNr je Tabelle (Buch 5088, Kommponist 5451, Titel 65738) | 1,4 KB |

### Fundstellen (wo steht ein Stück?)

In der App heißt die Ansicht dazu „Suchergebnisse“. Im Code und in dieser Doku bleibt „Fundstelle“ der Begriff für eine Zeile aus diesen Methoden.

Alle liefern dieselbe Zeilenstruktur: `BuchId, Buch, UNTERTITEL, Nr, TITEL, Zus, Komponist, Besetzung, Vorzeich, ImgURL`.

| Methode | Schlüssel | Beispiel |
|---|---|---|
| `GetTitelFundstellen` | `vTitel`, exakter Titel | „Lobe den Herren, den mächtigen König der Ehren“ → 214 Fundstellen, 94 KB |
| `GetEGLiederFundstellen` | `EGIxUr` (short) | EG 316 (IxUr 859) → 218 Fundstellen über 3 Titelvarianten |
| `GetBuchFundstellen` | `vQuellekurz` = `BuchId` | „101Bläserv“ → 101 Fundstellen, 40 KB |
| `GetKomponistFundstellen` | `vKomponist` = Feld `kurz` | „Fünfgeld T“ → 719 Fundstellen, 300 KB |

Zähler: `GetTitelAnzahl(Suchstring)`, `GetEGLiederFundstellenAnzahl(EGIxUr)`. `GetVerbindungPar` ist undokumentiert und wird nicht genutzt.

### Verhalten und Eigenheiten

- `GetTitel` ist ein SQL-`LIKE '%…%'`: Teilstring, ohne Groß-/Kleinschreibung, `_` und `%` wirken als Platzhalter. Mehrere Wörter werden als ein zusammenhängender String gesucht („Herren mächtigen“ findet nichts).
- `GetTitelFundstellen` vergleicht exakt (ohne Groß-/Kleinschreibung, nachgestellte Leerzeichen egal). Teilstrings liefern nichts.
- **Apostroph im Parameter führt zu HTTP 500** mit SQL-Syntaxfehler im Fehlertext. Die Queries werden per String-Verkettung gebaut (SQL-Injection). Workaround im Client: `'` → `''`. Dem Betreiber am 28.10.2026 gemeldet.
- Datenqualität: 184 Titel mit führenden/nachgestellten Leerzeichen, `Anlass` teils mit `\n`, Teil-Kürzel `Ol` vs. `OL`, Anzahl-Methode zu EG 317 meldet 9, Fundstellen-Methode liefert 10.
- Titel haben keine ID. Der Titel-String ist der Schlüssel für Fundstellen. Fundstellen identifizieren wir über `(BuchId, Nr, TITEL, Zus)`.
- Server ist ein privat betriebener DDNS-Host, Antwortzeiten 0,1 bis 1,5 s. Die App muss sparsam sein: keine Vollabzüge aller Fundstellen (786 Buchaufrufe, geschätzt ~30 MB XML).
- Cover-Bilder: Die API liefert `…/BilderBuch/mini60/<BuchId>.jpg` (42 × 60 px). Undokumentiert gibt es daneben `mini120/` (83 × 120 px, ca. 24 KB) und das Original direkt unter `BilderBuch/` (ca. 1000 × 1444 px, ca. 200 KB). Stichprobe 10/10 Bücher. Die App nutzt `mini120` in Listen und das Original im Buchkopf, mit Rückfall auf die API-URL (`CoverUrls`).
- Buch-Stammdaten enthalten Herausgeber, Verlag, Bestellnummer und Jahr. Seitenzahlen gibt es nicht, nur die Nummer im Heft.

### Zweite Quelle: REST-API von BlechWikiDK

Die App [BlechWikiDK](https://github.com/DieterKipp/BlechWikiDK) nutzt eine eigene JSON-API unter `https://teddymuetze.ddns.net/RestBlechWiki/api/`. Gleicher Datenbestand wie der LiteraService: Alle 1.255 EG-`Ix` stimmen in Titel und `IxUr` mit `GetEGLieder2` überein (Abgleich am 28.10.2026). Kein Login, Antwortzeiten 0,1 bis 0,2 s. Wir nutzen nur, was SOAP nicht kann, das Änderungsprotokoll:

| Endpunkt | Inhalt | Größe |
|---|---|---|
| `Version?Tabelle=Titel\|Buch\|Komponist&counter=N` | Änderungsprotokoll: Einträge mit `changecounter > N`, je mit `change` = `new`, `update` oder `delete` | `[]` = 2 Byte |

Eigenheiten:

- `counter=0` liefert die ganze Tabelle statt des Protokolls. Die App schickt deshalb nie 0.
- Stand Oktober 2026: Protokoll Buch bis Zähler 122 (203 Einträge), Komponist 78, Titel 69 (2.051 Einträge, 240 KB ab Zähler 1).

## 2. Konsequenz für Suche und Caching

Kernidee: **Tippen kostet keine Anfrage.** Alle Stammdaten (Titel, EG, Bücher, Komponisten) liegen nach dem ersten Start lokal in einer FTS-Datenbank. Eine Netzwerkanfrage gibt es erst, wenn der Nutzer einen Treffer öffnet, und auch dann nur einmal pro Titel.

### Stufe 1: Initial-Sync (einmalig, 5 Requests, ~2,3 MB)

`GetTitel("")`, `GetEGLieder2`, `GetBücher`, `GetKomponisten`, `GetEGLkAnhänge` → Room. Läuft beim ersten Start mit Fortschrittsanzeige, danach im Hintergrund.

### Stufe 2: Lokale Suche

Room-FTS4-Tabelle über normalisierte Texte (Kleinschreibung, ä→a, ß→ss, Satzzeichen entfernt, Whitespace getrimmt). Damit funktioniert, was die API nicht kann:

- mehrere Wörter in beliebiger Reihenfolge, Präfixsuche pro Wort („lob herr mächt“)
- EG-Nummer direkt: „316“ oder „EG 316“ → Lied, abhängig von der gewählten Landeskirche auch Anhangsnummern
- Bücher und Komponisten in derselben Ergebnisliste, gruppiert
- Ergebnisse ohne Netz und ohne Latenz

### Stufe 3: Fundstellen lazy laden, dauerhaft speichern

- Titel öffnen → `GetTitelFundstellen`. Ist der Titel ein EG-Lied, stattdessen `GetEGLiederFundstellen(IxUr)`, weil das Titelvarianten mit abdeckt (EG 316: 218 statt 214 Fundstellen).
- `IxUr` steht für die **Melodie**, `Ix` für das einzelne Lied. 110 Melodien gehören zu mehreren Liedtexten. Die EG-Abfrage liefert deshalb alle Sätze zur Melodie, auch unter anderem Text. Für Bläser ist das gewollt, die Detailansicht weist darauf hin.
- In der Suche erscheinen Titel, die einem EG-Liednamen entsprechen (1.136 von 1.255), nur als EG-Treffer.
- Ergebnis in Room mit `fetchedAt`. Beim nächsten Öffnen sofort aus dem Cache anzeigen (stale-while-revalidate), Neuladen nur, wenn der Eintrag älter als 30 Tage ist oder sich die Datenversion geändert hat.
- Parallele Anfragen zum selben Schlüssel werden zusammengelegt (single flight).

### Stufe 4: Inventar

Im Inventar stehen die Bücher aus dem Notenschrank des Chors. Eingetragen werden sie in einer Auswahlliste oder per Lesezeichen an jeder Buchkarte in den Suchergebnissen. Für jedes Buch im Inventar lädt ein WorkManager-Job `GetBuchFundstellen` (ca. 40 KB pro Buch, nacheinander). Danach:

- zeigt die Trefferliste der Suche direkt „Im Inventar: Bläserheft 2026 Bayern Nr. 10“, ohne Server-Anfrage
- stehen Bücher aus dem Inventar in jeder Liste von Suchergebnissen oben, mit Filter „Inventar“

Die Suche selbst bleibt ohne Filter. Gefiltert wird erst auf der Ergebnisseite.

Die Auswahlliste schlägt Bücher passend zur Landeskirche vor. Grundlage sind Wortanfänge in Titel, Untertitel, Herausgeber und Verlag (`RegionKeywords`). Das trifft etwa 120 der 786 Bücher, vor allem die Jahreshefte. Es ist eine Hilfe zum schnellen Finden, keine verlässliche Zuordnung.

Einschränkung: „Im Inventar“ vergleicht den normalisierten Titel. Sätze, die im Heft unter einem anderen Liedtext zur selben Melodie stehen, erkennt die Suche nicht. Die Suchergebnisse eines EG-Lieds zeigen sie trotzdem.

#### Inventar teilen

Damit nicht jedes Chormitglied den Notenschrank selbst durchgeht, lässt sich das Inventar als Code weitergeben, ohne Server: `BBW-SCCC-XXXX-XXXX-…` (`InventoryCode`).

- je Buch 4 Zeichen Crockford-Base32 mit den ersten 20 Bit von SHA-256 über Startwert und Buch-ID. Der Empfänger rechnet die Hashes über sein eigenes Verzeichnis nach, die IDs selbst stehen nicht im Code.
- `S` ist der Startwert (0 bis 31). Der Absender nimmt den kleinsten, bei dem keines seiner Bücher mit einem anderen Buch kollidiert. Bei 786 Büchern gibt es mit 20 Bit ein kollidierendes Paar.
- `CCC` ist eine 15-Bit-Prüfsumme über die sortierten IDs. Sie erkennt veränderte Codes und löst Kollisionen auf, die beim Empfänger durch neue Bücher entstehen.
- Der Code wird per Muster in beliebigem Text gefunden. Begleittext im Messenger stört nicht.
- Wege in die App: „Teilen“ einer Nachricht an die App (Ziel „Inventar übernehmen“) oder Inventar › ⋮ › „Inventar-Code einfügen“ mit einem Dialog, der einen Code aus der Zwischenablage vorbelegt.
- Enthält der Code Bücher, die das lokale Verzeichnis nicht kennt, prüft die App sofort die Datenversion (`SyncScheduler.checkNow`). Der Dialog wertet danach neu aus.
- **Kompatibilität:** Codes mit dem Präfix `BBW` müssen alle künftigen Versionen lesen können, auf jeder Plattform. Tester übertragen damit ihr Inventar aus der Testversion in den Release. Ein geändertes Format bekommt ein neues Präfix, `BBW` bleibt lesbar.

Eine eigene Dateiendung wurde verworfen: Android wählt die App über den MIME-Typ, den der Messenger mitgibt, und der ist bei unbekannten Endungen meist `application/octet-stream`.

Landeskirche und Inventar liegen in DataStore, nicht in Room. Room ist ein reiner Cache und wird bei Schema-Änderungen verworfen.

### Aktualisierung

- `GetlastAutonummer` (1,4 KB) dient als Versionsstempel. Ändert sich `Titel`, `Buch` oder `Kommponist`, werden die betroffenen Stammdaten neu geladen.
- Korrekturen und Löschungen ändern die AutoNr nicht. Die erkennt das Änderungsprotokoll der REST-API: Je Tabelle merkt sich die App den höchsten `changecounter` und fragt mit `counter=<Stand>`. Kommt etwas zurück, wird die Tabelle über SOAP neu geladen. Den ersten Stand sucht die App von 256 abwärts durch Halbieren, statt das ganze Protokoll zu laden (3 bis 4 Requests à 2 Byte je Tabelle).
- Ist der REST-Server nicht erreichbar, läuft der Abgleich nur über die AutoNr. Als Rückfallebene lädt der WLAN-Job alle 30 Tage alles neu.
- Prüfung beim App-Start höchstens alle 24 h, zusätzlich WorkManager-Job wöchentlich bei WLAN.
- Fundstellen: 30-Tage-TTL und Pull-to-refresh auf der Detailseite.

### Gesangbuch

- „Gesangbuch“ auf der Startseite listet Stammteil plus Anhang der gewählten Landeskirche nach Anlass, aus der lokalen Tabelle `eg_songs`. Der Stammteil ist sauber nach Anlass sortiert (569 Lieder, 38 Abschnitte). Im Anhang wechseln die Anlässe ständig (Niedersachsen/Bremen: 53 Wechsel bei 27 Anlässen). Anhangslieder stehen deshalb im Abschnitt ihres Anlasses hinter den Stammteil-Liedern (`HymnalSections`).

## 3. Technische Architektur

Kotlin, Jetpack Compose, Material 3, eine Activity, Unidirectional Data Flow (ViewModel → `StateFlow<UiState>`).

| Bereich | Wahl | Begründung |
|---|---|---|
| Netzwerk | OkHttp + selbst gebaute SOAP-Envelopes, `XmlPullParser` (Streaming) | 8 Methoden mit 0 bis 1 Parameter. ksoap2 bringt nichts außer Abhängigkeit. Streaming-Parser hält den 1-MB-Titelabruf speicherarm. |
| Persistenz | Room mit FTS4 | lokale Suche, Fundstellen-Cache, Favoriten |
| Einstellungen | DataStore | Landeskirche, Sync-Zeitpunkte, Datenversion |
| Hintergrund | WorkManager | Initial-Sync, Inventar-Download, Update-Check |
| DI | Hilt | Standard, gut testbar |
| Bilder | Coil mit Disk-Cache | Cover sind unveränderlich |
| Navigation | Navigation Compose (typsichere Routen) | |

### Module

```
:app                 Activity, Navigation, Theme, Hilt-Setup
:core:network        SoapClient, DataSet-Parser, DTOs, Escaping (' → '')
:core:database       Room-Entities, DAOs, FTS, Normalisierung
:core:data           Repositories (Sync, Search, Fundstellen, MeineBücher), Mapping DTO → Domain
:feature:search      Startscreen mit Suchfeld und gruppierten Ergebnissen
:feature:detail      Fundstellen zu Titel/EG-Lied, Filter nach Besetzung und Vorzeichen
:feature:library     Buch- und Komponisten-Detail, Inventar
```

Bei einem App-Umfang dieser Größe halte ich das für die Obergrenze. Wenn es schneller gehen soll, reichen `:app`, `:core` und ein Feature-Modul.

Stand jetzt existieren `:app`, `:core:network`, `:core:database` und `:core:data`. Die UI liegt vorerst in `:app`; eigene Feature-Module lohnen sich erst, wenn mehr Screens dazukommen. `:core:network` ist ein reines Kotlin/JVM-Modul: `org.xmlpull` liefert auf Android die Plattform, in den JVM-Tests kxml2 (`compileOnly` + `testImplementation`).

### Datenmodell (Room)

```
title(id PK auto, raw TEXT UNIQUE, norm TEXT, egIxUr INT NULL)
eg_song(ixUr, ix, lied, teil, nr, anlass)            PK(ixUr, teil)
book(bookId PK, name, subtitle, year, publisher, imgUrl, owned BOOL)
composer(kurz PK, name, born, died)
fundstelle(bookId, nr, titel, zus, composer, besetzung, vorzeichen)  PK(bookId, nr, titel, zus)
fetch_state(key PK, fetchedAt, dataVersion)          key = "titel:<raw>" | "eg:<ixUr>" | "buch:<id>"
favorite(titleRaw PK, addedAt)
search_fts  (FTS4, content: title/eg_song/book/composer, Spalten: norm, type, refId)
```

### Datenfluss Suche → Ergebnis

```
Tastendruck ─► SearchViewModel ─► SearchRepository.search(q)  (Room FTS, kein Netz)
Treffer antippen ─► DetailViewModel ─► FundstellenRepository.observe(key)
                                         ├─ Room-Flow liefert Cache sofort
                                         └─ falls fehlend/veraltet: SoapClient ─► Room upsert ─► Flow emittiert neu
```

## 4. Bedienung

- Startscreen = Suchfeld mit Fokus und Tastatur offen. Darunter zuletzt geöffnete Titel und Favoriten.
- Ergebnisse erscheinen beim Tippen, gruppiert: EG-Lied, Titel, Buch, Komponist.
- Detailseite „Suchergebnisse“: Fundstellen gruppiert nach Buch, eigene Bücher oben und markiert, Chips für Besetzung (2+2, 3+3 …) und Vorzeichen.
- Offline-Hinweis nur dann, wenn eine Fundstelle wirklich nicht im Cache ist.
- Landeskirche einmal beim Onboarding wählen, damit EG-Anhangsnummern stimmen.

## 5. Offene Punkte

- SQL-Injection: am 28.10.2026 an den Betreiber gemeldet. Die Lücke ist ihm bekannt, der IUSR hat nur Leserechte und keinen Zugriff aufs Dateisystem. Eine Behebung ist nicht angekündigt, der Client-Workaround (`'` → `''`) bleibt nötig.
- REST-API von BlechWikiDK: Die App fragt dort nur das Änderungsprotokoll ab. Fällt der Server weg, erkennt der Abgleich Korrekturen und Löschungen erst beim monatlichen Vollabgleich, alles andere läuft weiter.
- Klären, ob ein Initial-Download von ~2,3 MB pro Installation für den Betreiber in Ordnung ist, oder ob wir ein vorgebautes Datenbank-Asset in die APK legen (`createFromAsset`) und nur Deltas laden. Letzteres entlastet den Server und macht die App ab der ersten Sekunde nutzbar. Ich würde das so machen.
