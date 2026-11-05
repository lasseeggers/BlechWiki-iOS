# BlechWiki: API-Analyse und Architektur

Stand: 05.11.2026. Grundlage sind die Beschreibung des Betreibers Dieter Kipp und Testaufrufe gegen `https://pcportal.ddns.net/RestBlechWiki1/api/`. Diese Adresse hat Dieter Kipp am 03.11.2026 für die App eingerichtet. Die frühere Adresse `RestBlechWiki` lieferte zu diesem Zeitpunkt dieselben Daten. Bis Version 0.6.1 nutzte die App die SOAP-Schnittstelle `LiteraService`. Der Betreiber hat den Umstieg auf REST empfohlen, SOAP läuft aus.

## 1. Was die API kann

JSON über HTTPS (ASP.NET Web API auf IIS). Die Schnittstelle bietet nur GET. Kein Login, kein gzip, kein ETag, Antwortzeiten 0,1 bis 0,6 s. Eine automatisch erzeugte Liste der Routen ohne Beschreibungen steht unter `/RestBlechWiki1/Help`. Dieter Kipp schreibt die Adresse mit `http://`, die App nutzt HTTPS, weil iOS unverschlüsseltes HTTP blockiert.

### Stammdaten mit Änderungszähler

`Version?Tabelle=<Tabelle>&counter=<N>`. Jeder Datensatz trägt `change` (`new`, `update` oder `delete`) und `changecounter`, den Zähler seiner letzten Änderung. Datensätze, die gemeinsam geändert wurden, haben denselben Zähler.

- `counter=0` liefert die ganze Tabelle ohne gelöschte Einträge.
- `counter=N` liefert nur Einträge mit höherem Zähler, gelöschte eingeschlossen. Ohne Änderungen kommt `[]` (2 Byte).

| Tabelle | Schlüssel | Felder | Umfang bei `counter=0` |
|---|---|---|---|
| `Titel` | `ix` | `titel`, `titelohneKomma` | 9.915 Titel ohne Doppel, 1,2 MB. Nur `new` und `delete`. Die App nutzt sie nicht mehr, die Titel kommen aus den Fundstellen. |
| `Buch` | `buchId`, Zahl als Text | `buchkurz`, `buch`, `untertitel`, `erscheinjahr`, `herausgeber`, `herausgvorname`, `verlag`, `verlagsnummer` | 755 Bücher, 257 KB |
| `Komponist` | `id`, Zahl als Text | `kurz`, `komponist`, `friendlyKomponistName`, `geboren`, `gestorben`, `aliasvon` | 2.477 Einträge zu 2.423 ids, 475 KB |

Zählerstand am 01.11.2026: Titel 69, Buch 122, Komponist 78.

### EG-Lieder

`EG` liefert 2.290 Einträge, einen je Lied und EG-Teil: `ix`, `ixUr`, `nr`, `nr2`, `lied`, `anlass`, `egTeil` (282 KB). Die Tabelle ist statisch und hat keinen Änderungszähler. Die 1.255 verschiedenen `ix` stimmen mit der SOAP-Methode `GetEGLieder2` überein.

- `ix` steht für das Lied, `ixUr` für die **Melodie**. 110 Melodien gehören zu mehreren Liedtexten.
- `nr2` ist eine Unternummer wie bei EG 676.2, z. B. EG 577 mit `nr2` 1 und 2 im Anhang Österreich (vom Betreiber am 03.11.2026 bestätigt). Die App nutzt sie nicht.
- Teile: `Stamm`, die 13 Anhänge der Landeskirchen und `Add`. Oldenburg heißt hier `Ol`, in `EG?anhaenge=true` `OL`. Die App vergleicht die Kürzel ohne Groß- und Kleinschreibung.
- `Add` („Ergänzungen“): 11 Lieder, die unter einem anderen, meist englischen Titel bekannt sind und mit deutschem Text im EG stehen, z. B. „Go, tell it on the mountain“ (`ix` 1317) zu „Komm, sag es allen weiter“ (EG 225, `ix` 792). `ixUr` ist der `ix` des deutschen Lieds, die Fundstellen kommen daher über `EG/{ixUr}`. Die Nummern 601 bis 611 sind keine EG-Nummern. Die App zeigt statt einer Nummer „im EG als „Komm, sag es allen weiter“, EG 225“, die Nummernsuche findet diese Lieder nicht, und im Gesangbuch und in der Auswahl der Landeskirche erscheinen sie nicht.

### Fundstellen (wo steht ein Stück?)

In der App und im Code heißt die Ansicht dazu „Suchergebnisse“ (iOS `SuchergebnisseView`, Android `SuchergebnisseScreen`). „Fundstelle“ bleibt der Begriff für eine Zeile aus diesen Endpunkten, auch in Datenbank, API und Repository.

**Alle Fundstellen:** `Titel?titelzaehler=<N>` liefert jede Zeile mit höherem `Zähler`, bei 0 alle (am 05.11.2026 37.688 Zeilen, 7,5 MB, ohne gzip 1,1 MB wären möglich). Eingerichtet von Dieter Kipp am 04.11.2026 als Antwort auf unseren Wunsch nach stabilen IDs.

| Feld | Inhalt |
|---|---|
| `Zähler` | fest und aufsteigend, Schlüssel der Zeile. Gleich `titelZ` in den Abfragen unten. |
| `Quelle_kurz` | `buchkurz` des Buchs, Groß-/Kleinschreibung weicht teils ab („nordd5“ / „Nordd5“) |
| `Seite_Nr` | Nummer im Heft (Zahl) |
| `Titel`, `Titel2` | Titel und Zusatz wie „Vorspiel“ |
| `EGIx` | `ix` des EG-Lieds, 0 bei anderen Stücken. Über `eg_songs` zur Melodie (`ixUr`). |
| `Kompo_kurz`, `Kompo_kurz2` | `kurz` aus `Komponist`, eindeutig je Komponist |
| `Vorzeich`, `Besetzung` | wie unten `vorzeichen`, `besetzung` |

- Die Tabelle hat keinen Änderungsstatus. Laut Betreiber kommen fast nur neue Zeilen dazu, wenn ein Buch eingestellt wird. Eine korrigierte Zeile bekommt einen neuen Zähler. Gelöschte Zeilen erscheinen einfach nicht mehr.
- Die Zähler bleiben laut Betreiber auch beim Wiederherstellen aus einer Sicherung und beim Serverwechsel gleich.
- Am 04.11.2026 lieferte die Abfrage kurz nur die EG-Anhänge und privaten Sammlungen (Filter mit falschem Vorzeichen). Skript und App prüfen deshalb, ob genug Zeilen kommen.
- Zeilen ohne Buch in der Büchertabelle (EG-Anhänge, private Sammlungen) filtert der Server seit dem 04.11.2026 heraus. Die App ignoriert sie trotzdem, sie fallen durch den Join auf `books` weg.

**Einzelne Abfragen** (bis 1.3 die einzige Quelle):

| Endpunkt | Schlüssel | Beispiel |
|---|---|---|
| `Titel/{ix}` | `ix` aus `Titel` | 10374 „Alle Augen warten auf dich, Herre“ → 2 Fundstellen |
| `EG/{ixUr}` | Melodie | EG 316 (`ixUr` 859) → 218 Fundstellen, auch unter anderem Liedtext |
| `Buch/{buchId}` | `buchId` | 4035 „Bläsermusik 2025 - Württemberg“ → 76 Stücke, 17 KB |
| `Komponist/{id}` | `id` aus `Komponist` | 2000 „Kreuter, Walter“ |

Alle liefern dieselbe Zeilenstruktur: `buch, nr, titel, zus, komponist, besetzung, vorzeichen, titelZ, buchId, quellekurz`. `titelZ` ist der `Zähler` von oben (als Text), bei `EG/` und `Komponist/` fehlt er. Die App nutzt nur noch `Buch/{buchId}`, um gelöschte Zeilen eines Buchs zu finden. Die Felder stimmen für Buch 4035 mit der Tabelle oben überein. Einzige Ausnahme: Ein leerer `Kompo_kurz` erscheint hier als „NN“.

Die Beschreibung des Betreibers nennt für `EG/{…}` den `ix`. Sein Beispiel und unsere Tests zeigen, dass die Melodie (`ixUr`) gemeint ist.

### Verhalten und Eigenheiten

- Unbekannte IDs liefern HTTP 500 mit `{"Message":"Fehler"}`.
- Zwei Titel kommen doppelt vor und unterscheiden sich nur durch ein Leerzeichen am Ende („Kanon“, ix 4292 und 8358). Sie haben getrennte Fundstellen, die App führt beide.
- Komponisten: Schreibvarianten stehen als eigene Zeilen mit derselben `id` und demselben `kurz`, nach allen Haupteinträgen. `aliasvon` nennt den Hauptnamen, beim Haupteintrag ist es leer. Die App speichert nur den Haupteintrag. `geboren` und `gestorben` sind Text, meist eine Jahreszahl, auch „um 1600“ oder „nach 1650“, leer als `""` oder `" "`.
- Das Format hat sich am 05.11.2026 zweimal geändert. Bis dahin stand das Alias als `( alias … )` und die Lebensdaten in Formen wie `(1685-1750)` oder `(um 1600-nach 1650)` am Ende von `komponist`. Nachmittags hießen die Felder kurz `AutoNr`, `Komponist`, `FriendlyKomponistName`, `Geboren` und `Gestorben`, damit brach in 1.3.0 der Abgleich ab. Seit dem Abend gibt es wieder `id`, `komponist` und `friendlyKomponistName`, die Lebensdaten nur noch in `geboren` und `gestorben`. 1.3.0 und 1.3.1 laufen damit, zeigen aber keine Lebensdaten. Versionen nach 1.3.1 lesen alle drei Formate und achten bei den Feldnamen nicht auf Groß- und Kleinschreibung. Gibt es `aliasvon`, nehmen sie Lebensdaten und Alias aus den eigenen Feldern.
- Bücher: SOAP lieferte 786. Im neuen Datenmodell fehlen 13 Pseudo-Bücher für die EG-Anhänge („EG NB“ usw.) und 18 Einträge „Einzelaus…“.
- `EG?anhaenge=true` liefert die Teile des EG als `EGTeilkurz` und `EGTeil`, z. B. `NB` = Niedersachsen/Bremen, `M` = Mecklenburg, dazu `Stamm` und `Add`. Die App lädt die Liste beim Vollabgleich. Ist sie nicht lesbar oder leer, nimmt sie eine eingebaute Liste mit Stand 03.11.2026, damit der Abgleich nicht scheitert.
- `Titel?search=` liefert höchstens 100 Fundstellen ohne `buchId` und wird nicht genutzt.
- Cover-Bilder: `https://teddymuetze.ddns.net/Bilder/BilderBuch/<buchkurz>.jpg` im Original (ca. 1000 × 1444 px, ca. 200 KB), laut Betreiber zusätzlich unter `mini60/`, `mini120/` und `mini240/`. Die App nutzt `mini120` in Listen und das Original im Buchkopf, mit Rückfall auf `mini60` (`CoverUrls`).
- Buch-Stammdaten enthalten Herausgeber, Verlag, Bestellnummer und Jahr. Seitenzahlen gibt es nicht, nur die Nummer im Heft.
- Der Server ist ein privat betriebener DDNS-Host. Die App muss sparsam sein. Deshalb bringt sie die Fundstellen mit, statt sie bei jeder Installation zu laden.

## 2. Konsequenz für Suche und Caching

Kernidee: **Tippen und Öffnen kosten keine Anfrage.** Bücher, Komponisten, EG-Lieder und alle Fundstellen liegen lokal in einer Datenbank mit FTS-Index.

### Stufe 1: Erster Start

- Die Fundstellen bringt die App mit: `scripts/fundstellen-stand.sh` lädt `Titel?titelzaehler=0`, behält die Zeilen aus Büchern der Büchertabelle und legt sie als `data/fundstellen.json.gz` (ca. 950 KB) mit Zeitpunkt in `data/fundstellen.stand` ab. Android nimmt `data/` als Asset-Ordner (der Build entpackt die Datei, das APK speichert sie komprimiert, ca. 1 MB), iOS kopiert beide Dateien in der Build-Phase „Fundstellen-Stand“ ins App-Paket und entpackt beim Import. `data/` ist privat und wird nicht ins öffentliche Repo exportiert. Fehlt der Stand (Build aus dem öffentlichen Repo), lädt die App alle Fundstellen vom Server.
- Ist der mitgelieferte Stand ein anderer als der zuletzt importierte (`sync_state.importedSnapshot`), ersetzt er alle Fundstellen, auch ohne Netz. So bringt jedes Update Korrekturen und Löschungen mit.
- Danach `Version?…&counter=0` für Bücher und Komponisten, dazu `EG` und `EG?anhaenge=true` (ca. 1 MB), und `Titel?titelzaehler=<höchster Zähler des Stands>` für alles, was seit dem Stand dazugekommen ist.
- Läuft im Hintergrund, während die Einführung zu sehen ist (iOS `OnboardingView`, Android `OnboardingScreen`). Nach der Tour folgen zwei Schritte der Einrichtung. Der letzte schlägt Bücher fürs Inventar vor und braucht dafür die Bücher-Tabelle. Bis dahin zeigt sie den Ladestand. Die Auswahl der Landeskirche davor nimmt ohne Daten die eingebaute Liste der EG-Anhänge. Ob die Einführung erscheint, entscheidet die App einmal beim Start (`needsOnboarding`): nicht, wenn sie schon durchlaufen wurde oder schon eine Landeskirche oder Bücher eingetragen sind. Danach holt die App nur noch Änderungen, siehe [Aktualisierung](#aktualisierung).

### Stufe 2: Lokale Suche

Room-FTS4-Tabelle über normalisierte Texte (Kleinschreibung, ä→a, ß→ss, æ→ae, ø→o, Ligaturen wie ﬁ→fi, Satzzeichen entfernt, Whitespace getrimmt). Eine Anfrage nutzt höchstens 16 verschiedene Wörter, sonst wird der FTS-Ausdruck für SQLite zu groß. Damit funktioniert, was die API nicht kann:

- mehrere Wörter in beliebiger Reihenfolge, Präfixsuche pro Wort („lob herr mächt“)
- EG-Nummer direkt: „316“, „EG 316“, „EG316“ oder „EG-316“ (auch mit Anführungszeichen oder Punkt) → Lied, abhängig von der gewählten Landeskirche auch Anhangsnummern
- Bücher und Komponisten in derselben Ergebnisliste, gruppiert
- Ergebnisse ohne Netz und ohne Latenz

Titel-Treffer kommen aus den Fundstellen, ein Treffer je normalisiertem Titel. Schreibweisen wie „Nun bitten wir den heiligen Geist“ und „… Heiligen Geist“ werden ein Treffer, angezeigt in der häufigsten. Titel, die einem EG-Liednamen entsprechen, erscheinen nur als EG-Treffer.

### Stufe 3: Suchergebnisse aus der lokalen Tabelle

- EG-Lied: alle Fundstellen, deren `EGIx` zur selben Melodie gehört, auch unter anderem Liedtext. Für Bläser ist das gewollt, die Detailansicht weist darauf hin. Ergibt für EG 316 dieselben 218 Fundstellen wie `EG/859`.
- Titel: alle Fundstellen mit diesem normalisierten Titel.
- Buch: über `Quelle_kurz` = `buchkurz`, ohne Groß-/Kleinschreibung.
- Komponist: `Kompo_kurz` oder `Kompo_kurz2` = `kurz` des Komponisten. Angezeigt wird der Name aus der Komponisten-Tabelle, fehlt der Kurzname dort (z. B. „Hassler H L“), der Kurzname.
- Sortierung: neueste Bücher zuerst, im Buch nach Nummer.

### Stufe 4: Inventar

Im Inventar stehen die Bücher aus dem Notenschrank des Chors. Eingetragen werden sie in einer Auswahlliste oder per Lesezeichen an jeder Buchkarte in den Suchergebnissen. Ihr Inhalt liegt wie alle Fundstellen schon lokal. Damit:

- zeigt die Trefferliste der Suche direkt „Im Inventar: Bläserheft 2026 Bayern Nr. 10“, ohne Server-Anfrage. Bei EG-Liedern zählen alle Sätze zur Melodie, bei Titeln jede Schreibweise.
- stehen Bücher aus dem Inventar in jeder Liste von Suchergebnissen oben, mit Filter „Inventar“

Die Suche selbst bleibt ohne Filter. Gefiltert wird erst auf der Ergebnisseite.

Die Auswahlliste schlägt Bücher passend zur Landeskirche vor. Grundlage sind Wortanfänge in Titel, Untertitel, Herausgeber und Verlag (`RegionKeywords`). Das trifft etwa 120 der 755 Bücher, vor allem die Jahreshefte. Es ist eine Hilfe zum schnellen Finden, keine verlässliche Zuordnung.

#### Inventar teilen

Damit nicht jedes Chormitglied den Notenschrank selbst durchgeht, lässt sich das Inventar als Code weitergeben, ohne Server: `BW2…` (`InventoryCode`).

- Der Code enthält die numerischen Buch-IDs (`buchId`) selbst, aufsteigend sortiert. Gespeichert wird je Buch nur der Abstand zur vorigen ID, mit Exp-Golomb kodiert. Die Ordnung `k` (4 Bit) wählt der Absender so, dass der Code am kürzesten wird. Benachbarte IDs, etwa bei Heftreihen, kosten dann nur `k` + 1 Bit.
- Davor steht eine 20-Bit-Prüfsumme (SHA-256 über die IDs). Sie erkennt veränderte Codes und legt fest, wo ein Code im Text endet.
- Zeichen: Crockford-Base32 ohne Striche, damit ein Doppelklick den ganzen Code markiert. 13 Bücher ergeben 26 Zeichen, 40 zufällig gewählte etwa 64, alle 755 Bücher 220.
- Der Empfänger braucht kein gleiches Verzeichnis. Ein Buch, das er noch nicht kennt, erscheint nach dem nächsten Abgleich.
- Der Code wird in beliebigem Text gefunden. Begleittext im Messenger stört nicht. Innerhalb des Codes werden Striche, Leerraum, Zeilenumbrüche und Zitatzeichen „>“ übersprungen, falls jemand ihn aufteilt oder eine Mail ihn umbricht. Die Teile werden angehängt, bis die Prüfsumme stimmt. So bleibt ein Wort hinter dem Code draußen. „BW2“ mit Leerraum dahinter gilt nur als Code, wenn die Prüfsumme stimmt, damit Text wie „Die BW2 ist da“ nicht als beschädigter Code gemeldet wird.
- Wege in die App: „Teilen“ einer Nachricht an die App (Ziel „Inventar übernehmen“) oder im Inventar über das Menü „Inventar-Code einfügen“. Auf Android belegt der Dialog einen Code aus der Zwischenablage vor. Auf iOS gibt es dafür den Knopf „Einsetzen“, weil iOS beim Lesen der Zwischenablage sonst jedes Mal nachfragt.
- Enthält der Code Bücher, die das lokale Verzeichnis nicht kennt, prüft die App sofort die Datenversion (Android `SyncScheduler.checkNow`, iOS `SyncCoordinator.checkCatalogNow`). Der Dialog wertet danach neu aus. Ist danach immer noch kein einziges Buch bekannt, gilt der Code als verändert.
- **Kompatibilität:** Ab Version 1.0 müssen alle künftigen Versionen Codes mit dem Präfix `BBW` lesen können, auf jeder Plattform. Ein geändertes Format bekommt ein neues Präfix, `BBW` bleibt lesbar. Bis Version 1.1 erzeugten die Apps `BBW-SCCC-XXXX-…` (`LegacyInventoryCode`): je Buch die ersten 20 Bit von SHA-256 über Startwert und Buch-ID, dazu Startwert und 15-Bit-Prüfsumme. Der Empfänger rechnet die Hashes über sein eigenes Verzeichnis nach. Neue Versionen lesen diese Codes weiter, erzeugen sie aber nicht mehr. Steht in einem Text ein gültiger `BW2`-Code, geht er vor. Mit dem Umstieg auf REST in 0.7.0 haben sich die Buch-IDs geändert (vorher der Kurzname, jetzt die Zahl). Inventar und Codes aus 0.6.1 und älter gelten nicht mehr, vor 1.0 war das in Ordnung.

Eine eigene Dateiendung wurde verworfen: Android wählt die App über den MIME-Typ, den der Messenger mitgibt, und der ist bei unbekannten Endungen meist `application/octet-stream`.

Landeskirche und Inventar liegen in DataStore (iOS: UserDefaults der App Group), nicht in Room bzw. SQLite. Die Datenbank enthält nur, was vom Server kommt oder mitgeliefert ist, und wird bei Schema-Änderungen verworfen (zuletzt iOS Schema 5, Android Room 7). Nach einem solchen Update importiert die App den mitgelieferten Stand und lädt Bücher, Komponisten und EG neu, ca. 1 MB. Die Listen liegen deshalb in einer eigenen Datenbank, siehe unten.

### Stufe 5: Listen

„Favoriten“ und eigene Listen, etwa für ein Konzert. Favoriten gibt es immer (id `favoriten`), sie lassen sich weder löschen noch umbenennen. Ein Eintrag ist eine von drei Arten:

- `title`: ein Lied unabhängig vom Buch. Die Liste zeigt, in wie vielen Büchern es steht und wo im Inventar.
- `piece`: eine Fundstelle, also ein Stück in einem bestimmten Buch.
- `eg`: ein EG-Lied. Bücher und Inventar laufen wie in der Suche über die Melodie.

Jeder Eintrag hat eine eigene ID, eine Position und einen optionalen Kommentar (höchstens 300 Zeichen). Dasselbe Lied darf in einer Liste mehrfach stehen, etwa als Eingangs- und Schlusslied. In den Favoriten nicht, dort schaltet der Stern um.

Gespeichert werden die Rohfelder (Titel, `buchId`, Nr., Zusatz, EG-`ix`) und zur Anzeige Buchtitel und EG-Nummer, damit ein Eintrag auch ohne Stammdaten lesbar bleibt. Zum Vergleichen (Stern, „Schon enthalten“) leitet die App daraus einen Schlüssel ab, auf beiden Plattformen gleich und mit denselben Beispielen getestet (`ListEntryKey`):

- Lied: `t:` + normalisierter Titel
- Fundstelle: `p:` + `buchId` + `|` + Nr. + `|` + normalisierter Titel + `|` + normalisierter Zusatz. Der Zähler `titelZ` taugt nicht, er ändert sich bei Korrekturen.
- EG-Lied: `eg:` + `ix`

Ändert sich die Normalisierung, rechnet eine Migration die Schlüssel aus den Rohfeldern neu. Listen teilen ist noch nicht eingebaut. Ein Code dafür würde die Rohfelder übertragen, nicht die Schlüssel, damit der Empfänger mit seiner eigenen Normalisierung vergleicht.

Speicher: `listen.db` (Room, `ListsDatabase`) bzw. `listen.sqlite` (`ListsDatabase`, App Group). Beide haben echte Migrationen und werden nie verworfen. Android exportiert das Schema nach `android/core/database/schemas/`. Auf iOS darf ein Fehler beim Öffnen weder die Datei löschen noch die übrige App blockieren.

Sicherung: Auf Android nehmen die Backup-Regeln (`data_extraction_rules.xml`, `backup_rules.xml`) `listen.db` und DataStore mit und lassen `blechwiki.db` weg, die mit allen Fundstellen groß ist und sich neu laden lässt. Auf iOS ist `listen.sqlite` anders als `blechwiki.sqlite` nicht vom Backup ausgenommen.

### Aktualisierung

- Je Tabelle merkt sich die App den höchsten `changecounter` und fragt mit `counter=<Stand>`, bei den Fundstellen mit `titelzaehler=<höchster Zähler>`. Ohne Änderungen sind das drei Requests à 2 Byte.
- Bücher übernimmt die App Eintrag für Eintrag: neu, geändert oder gelöscht. Neue Fundstellen kommen dazu, eine Korrektur als neue Zeile. Der Suchindex des Bereichs wird danach aus der lokalen Tabelle neu gebaut.
- Gelöschte Fundstellen meldet der Server nicht. Beim Öffnen eines Buchs und für die Bücher im Inventar fragt die App höchstens alle 30 Tage `Buch/{buchId}` und löscht Zeilen dieses Buchs, deren Zähler dort als `titelZ` fehlt. Vorher holt sie neue Fundstellen, damit eine Korrektur nicht fehlt, wenn ihre alte Fassung verschwindet. Eine leere Antwort löscht nichts. Andere Seiten (EG-Lied, Titel, Komponist) holen beim Herunterziehen nur neue Fundstellen.
- „Alle Daten neu laden“ in den Einstellungen (Mac: Menü „Darstellung“) lädt alles vom Server, auch alle Fundstellen (ca. 8,5 MB), nach einer Rückfrage. Für den Fall, dass trotzdem etwas fehlt oder falsch ist.
- Komponisten lädt die App bei jeder Änderung ganz neu (475 KB). Schreibvarianten haben dieselbe `id`, eine einzelne Änderung lässt sich nicht eindeutig einer Zeile zuordnen.
- Die EG-Lieder haben keinen Zähler. Sie kommen beim ersten Abgleich und beim Vollabgleich von Büchern, Komponisten und EG, den der WLAN-Job alle 30 Tage macht. Fundstellen lädt er dabei nicht ganz.
- Prüfung beim App-Start höchstens alle 24 h. Android hat zusätzlich einen WorkManager-Job, der wöchentlich im WLAN läuft. iOS hat keinen Hintergrund-Job, dort läuft der Vollabgleich beim Öffnen im WLAN.
- Zeilen, denen ein Pflichtfeld fehlt, überspringt die App. Der gemerkte Zähler rückt trotzdem bis zum höchsten `changecounter` der Antwort vor, auch wenn er zu einer übersprungenen Zeile gehört. Sonst käme ein einzelner fehlerhafter Eintrag bei jedem Abgleich wieder und hielte ihn auf. Als Fehler gilt eine Antwort nur, wenn eine ganze Tabelle leer oder ganz unlesbar zurückkommt oder sich in einer Liste der Änderungen nicht einmal ein Zähler lesen lässt. Dann bleibt der alte Stand.
- Inventar-Bücher, die nicht mehr im Verzeichnis stehen (vom Server gelöscht), gleicht die App nicht ab. Der Server beantwortet unbekannte Buch-IDs mit HTTP 500.
- iOS liest über eine zweite, nur lesende SQLite-Verbindung. Ein laufender Abgleich, der den Suchindex schreibt, hält so keine Anzeige auf (WAL).

### Gesangbuch

- „Gesangbuch“ auf der Startseite listet Stammteil plus Anhang der gewählten Landeskirche nach Anlass, aus der lokalen Tabelle `eg_songs`. Der Stammteil ist sauber nach Anlass sortiert (569 Lieder, 38 Abschnitte). Im Anhang wechseln die Anlässe ständig (Niedersachsen/Bremen: 53 Wechsel bei 27 Anlässen). Anhangslieder stehen deshalb im Abschnitt ihres Anlasses hinter den Stammteil-Liedern (`HymnalSections`).

## 3. Technische Architektur

Kotlin, Jetpack Compose, Material 3, eine Activity, Unidirectional Data Flow (ViewModel → `StateFlow<UiState>`).

| Bereich | Wahl | Begründung |
|---|---|---|
| Netzwerk | OkHttp + JSON-Parser von kotlinx.serialization (ohne Compiler-Plugin) | 6 GET-Endpunkte mit flachen Zeilen. Eigene DTOs mit Mapping von Hand, weil die API leere Werte als `""` liefert und Zahlen teils als Text. |
| Persistenz | Room mit FTS4 | lokale Suche, alle Fundstellen; Listen in eigener Room-Datenbank mit Migrationen |
| Einstellungen | DataStore | Landeskirche, Sync-Zeitpunkte, Datenversion |
| Hintergrund | WorkManager | Initial-Sync, Abgleich der Inventar-Bücher, Update-Check |
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
books(id PK, shortName NOCASE, title, subtitle, year, editor, publisher, publisherNumber, coverUrl)
composers(id PK, shortName NOCASE, name, born, died)
eg_songs(id PK auto, ix, ixUr, title, part, number, occasion)
eg_appendices(code PK, name)
search_index  (FTS4 über content; norm, label, detail, type, refKey, refNumber)
sync_state(id PK = 0, bookChangeCounter, composerChangeCounter, pieceCounter, checkedAtMillis, fullSyncAtMillis,
           piecesCheckedAtMillis, importedSnapshot)
pieces(counter PK, bookShortName NOCASE, number, title, titleNorm, addition, keySignature, egIx, scoring,
       composerShortName NOCASE, composerShortName2 NOCASE)
book_checks(bookId PK, checkedAtMillis)   letzter Abgleich mit Buch/{id}
```

Auf iOS liegt dasselbe Schema in SQLite (`AppDatabase`).

Listen, getrennt in `listen.db` bzw. `listen.sqlite`:

```
lists(id PK, name, createdAtMillis, updatedAtMillis)
list_entries(id PK, listId → lists ON DELETE CASCADE, position, kind, entryKey, title,
             bookId, bookTitle, number, addition, egIx, egIxUr, egLabel, comment, addedAtMillis)
```

### Datenfluss Suche → Ergebnis

```
Tastendruck ─► SearchViewModel ─► SearchRepository.search(q)  (Room FTS, kein Netz)
Treffer antippen ─► SuchergebnisseViewModel ─► FundstellenRepository.observe(query)  (Join pieces/books/composers, kein Netz)
                                              └─ Buch, Abgleich älter als 30 Tage: Buch/{id} ─► gelöschte Zeilen weg ─► Flow emittiert neu
```

## 4. Bedienung

- Startseite = Suchfeld, darunter Inventar, Listen, Gesangbuch, Einstellungen und Hilfe. „Hilfe“ öffnet die Einführung über der ganzen App, ist also keine Seite rechts daneben.
- Ergebnisse erscheinen beim Tippen, gruppiert: EG-Lied, Titel, Buch, Komponist.
- Detailseite „Suchergebnisse“: Fundstellen gruppiert nach Buch, eigene Bücher oben und markiert, Chips für Besetzung (2+2, 3+3 …) und für „nur Inventar“. Das Vorzeichen steht an jeder Fundstelle.
- Die Landeskirche wählt man in den Einstellungen, in der Einführung oder über den Hinweis in Inventar und Gesangbuch. Bis dahin zeigt das Gesangbuch nur den Stammteil.
- iOS auf iPad, Mac (Mac Catalyst) und aufgeklapptem iPhone Duo: Suche und Startseite links, die gewählte Seite rechts (`NavigationSplitView`). Auf schmalen Bildschirmen klappt das zum selben Stapel zusammen wie auf dem iPhone. Listen rechts werden ab 720 pt Spaltenbreite mittig begrenzt.
- Nur auf dem Mac: Jeder Befehl steht auch in der Menüleiste („Gehe zu“, „Inventar“, „Aktualisieren“ unter „Darstellung“, Einführung, Impressum und Datenschutz unter „Hilfe“), die Seiten melden ihre Befehle per `focusedSceneValue`. ⌘, öffnet ein Einstellungsfenster mit der Landeskirche. Die Besetzung wählt man im Aufklappmenü statt in einer seitlich scrollenden Chip-Reihe, Buchzeilen haben ein Kontextmenü. Catalyst zeigt `.principal` in der Toolbar nicht, Unterzeilen stehen dort in der Liste. Überschriften in Inventar und Gesangbuch scrollen mit, statt oben stehen zu bleiben, weil ihr Hintergrund unter Catalyst nach dem Zurückscrollen über dem Listenanfang liegen blieb. Den aktuellen Anlass im Gesangbuch zeigt dort der Anlass-Knopf in der Toolbar. Die Menübefehle erscheinen auch auf dem iPad mit Tastatur.
- Android ab 600 dp Fensterbreite (aufgeklapptes Foldable, Tablet, Handy quer) genauso: Suche links, Seite rechts, Seite höchstens 840 dp breit. Beide Formen teilen sich einen `NavHost`, beim Auf- und Zuklappen bleibt die geöffnete Seite stehen.

## 5. Offene Punkte

- Wünsche an den Betreiber, Stand 05.11.2026:
  - Erledigt: nur GET, feste Adresse mit Version (`RestBlechWiki1`), Endpunkt für die EG-Teile, Lebensdaten und Schreibvarianten der Komponisten als eigene Felder (05.11.2026), alle Fundstellen mit festen IDs (`Titel?titelzaehler=`, 04.11.2026).
  - Nicht möglich: gzip (der Betreiber bekommt es nicht eingerichtet) und ein Änderungsstatus für Fundstellen. Deshalb Stand in der App und Abgleich pro Buch.
  - Gestrichen: alle Zählerstände in einem Aufruf (spart nur zwei Anfragen mit je 2 Byte Antwort) und ein neuer Zähler für ein Buch, wenn sich seine Fundstellen ändern. Der Bestand ändert sich bis auf Korrekturen kaum, das Neuladen nach 30 Tagen reicht.
  - Offen: HTTP 404 bei unbekannter ID.
  - `RestBlechWiki` bleibt laut Betreiber vorerst erreichbar, für Installationen bis 1.0.
- Komponisten: Die Schreibvarianten (`aliasvon`) könnten in die Suche, damit „Lassus“ Orlando di Lasso findet. Bisher speichert die App nur den Haupteintrag.
