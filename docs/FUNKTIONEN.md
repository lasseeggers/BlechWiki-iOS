# Funktionen

BlechWiki beantwortet eine Frage: In welchem Bläserheft steht dieses Stück, und haben wir das Heft im Notenschrank? Die Daten kommen von [blechwiki.de](https://www.blechwiki.de/), gesucht wird lokal auf dem Gerät.

Screenshots: links Android (Galaxy S8, Android 9), rechts iOS (Simulator iPhone 18 Pro). Beide mit Landeskirche Nordelbien und demselben Inventar aus 6 Büchern.

[← Zurück zur README](../README.md)

## Startseite

| Android | iOS |
|:---:|:---:|
| <img src="screenshots/android-startseite.png" width="260" alt="Startseite Android"> | <img src="screenshots/ios-startseite.png" width="260" alt="Startseite iOS"> |

- Beim ersten Start erklärt eine Tour auf vier Seiten Suche, Suchergebnisse, Inventar und Gesangbuch, jeweils mit Screenshot. Wischen oder „Weiter“ blättert, „Überspringen“ oder „Einrichten“ öffnet die Einrichtung. Die sieht aus wie eine normale Seite der App, damit klar ist, dass hier etwas einzustellen ist: In Schritt 1 wählt man die Landeskirche, in Schritt 2 hakt man die ersten Hefte fürs Inventar an, aus den Vorschlägen für die Landeskirche und den Choralbüchern. Wer schon eine Landeskirche oder Bücher eingetragen hat, sieht die Einführung nicht. In den App-Informationen lässt sie sich unter „Einführung ansehen“ jederzeit wieder öffnen, mit „Schließen“ oben links.
- Währenddessen lädt die App im Hintergrund das Liederverzeichnis (einmalig etwa 2 MB) und danach den Inhalt der angehakten Hefte. Danach läuft die Suche ohne Internet. Ist das Verzeichnis bei der Bücherauswahl noch nicht da, zeigt die Seite den Ladestand. Die Landeskirche lässt sich auch ohne Netz wählen, dafür hat die App eine eingebaute Liste.
- **Inventar** zeigt, wie viele Bücher eingetragen sind und ob ihr Inhalt schon offline vorliegt.
- **Gesangbuch** öffnet alle EG-Lieder nach Anlass, siehe unten.
- **Landeskirche** legt fest, welche Nummern aus den EG-Anhängen erscheinen und welche Hefte im Inventar vorgeschlagen werden.
- **App-Informationen** öffnet die Einführung erneut, erklärt, wie die App ihre Daten aktualisiert, und zeigt das Datum der letzten Prüfung, die Versionsnummer sowie Links zu Impressum und Datenschutzerklärung. Die App fragt höchstens einmal am Tag nach neuen und korrigierten Büchern, Liedern und Komponisten und lädt nur, was sich geändert hat. Einmal im Monat lädt sie im WLAN zur Sicherheit alles neu.

## Suche

| Android | iOS |
|:---:|:---:|
| <img src="screenshots/android-suche.png" width="260" alt="Suche Android"> | <img src="screenshots/ios-suche.png" width="260" alt="Suche iOS"> |

- Ein Suchfeld für Liedtitel, EG-Nummer, Buch und Komponist. Wortanfänge reichen, „lob herr“ findet „Lobe den Herren“.
- Treffer sind gruppiert: EG-Lieder, Titel, Bücher, Komponisten. EG-Lieder stehen oben.
- Steht ein Stück in einem Buch aus dem Inventar, zeigt die Trefferliste das direkt mit Buch und Nummer an, hier „Norddeutsches Bläserheft 4 Nr. 7“.
- Auf iOS 26 und neuer sitzt das Suchfeld unten, in Reichweite des Daumens. Auf älteren Versionen steht es oben unter dem Titel.

## Suchergebnisse

| Android | iOS |
|:---:|:---:|
| <img src="screenshots/android-suchergebnisse.png" width="260" alt="Suchergebnisse Android"> | <img src="screenshots/ios-suchergebnisse.png" width="260" alt="Suchergebnisse iOS"> |

- Alle Bücher, in denen ein Lied steht, mit Nummer, Bearbeiter, Besetzung und Vorzeichen. Im Bild „This little Light of mine“: 5 Bücher, 2 davon im Inventar.
- Ein Tipp auf einen Bearbeiter oder Komponisten zeigt alle seine Stücke, wie die Suche nach ihm. Namen ohne Eintrag bei BlechWiki, etwa „NN“, sind nicht verlinkt.
- Bei EG-Liedern zählt die Melodie. Die Liste enthält auch Sätze, die im Heft unter einem anderen Liedtext stehen.
- Filter oben: nur Bücher aus dem Inventar oder eine bestimmte Besetzung (2+2, 3+2, 2+2+1 Solotrompete …).
- Bücher aus dem Inventar stehen zuerst. Das Lesezeichen am Buch nimmt es ins Inventar auf oder entfernt es.
- Einmal geladene Suchergebnisse bleiben gespeichert. Ohne Internet zeigt die App den gespeicherten Stand mit Datum.

## Buchansicht

| Android | iOS |
|:---:|:---:|
| <img src="screenshots/android-buch.png" width="260" alt="Buchansicht Android"> | <img src="screenshots/ios-buch.png" width="260" alt="Buchansicht iOS"> |

- Cover, Jahr, Herausgeber, Verlag und Anzahl der Stücke. Ein Tipp aufs Cover zeigt es groß. Ist der Herausgeber auch als Komponist eingetragen, führt ein Tipp auf seinen Namen zu seinen Stücken.
- Inhaltsverzeichnis des Hefts, filterbar nach Besetzung und durchsuchbar („In diesem Buch suchen“).
- **Titel A–Z** sortiert das Inhaltsverzeichnis alphabetisch statt nach Nummer im Heft.
- Erreichbar aus den Suchergebnissen (Tipp auf ein Buch), aus dem Inventar und aus der Suche.

## Gesangbuch

| Android | iOS |
|:---:|:---:|
| <img src="screenshots/android-gesangbuch.png" width="260" alt="Gesangbuch Android"> | <img src="screenshots/ios-gesangbuch.png" width="260" alt="Gesangbuch iOS"> |

- Alle Lieder aus dem Stammteil des EG und dem Anhang der gewählten Landeskirche, gruppiert nach Anlass wie im Gesangbuch (Advent, Weihnachten, …, Abend).
- Lieder aus dem Anhang stehen beim passenden Anlass hinter denen aus dem Stammteil.
- Zum Springen gibt es die Liste aller Anlässe mit ihren Nummern. Auf Android öffnet sie das Feld **Anlass** über der Liste, das zugleich den aktuellen Anlass zeigt. Auf iOS öffnet sie der Knopf oben rechts, den aktuellen Anlass zeigt die Abschnittsüberschrift, die beim Scrollen oben stehen bleibt.
- Ein Tipp auf ein Lied öffnet seine Suchergebnisse.

## Inventar

| Android | iOS |
|:---:|:---:|
| <img src="screenshots/android-inventar.png" width="260" alt="Inventar Android"> | <img src="screenshots/ios-inventar.png" width="260" alt="Inventar iOS"> |

- Bücher aus dem Notenschrank abhaken. Ihr Inhalt wird geladen und ist danach offline verfügbar.
- Oben stehen Vorschläge für die gewählte Landeskirche, darunter Choralbücher und alle übrigen Bücher, neueste zuerst. Ein Suchfeld filtert die Liste.
- **Inventar teilen:** Die App erzeugt einen Code (`BW2…`) und verschickt ihn per Messenger oder Mail. So bekommt der ganze Chor dieselbe Liste.
- **Inventar übernehmen:** Die Nachricht mit dem Code an die App teilen oder den Code im Menü einfügen. Das bisherige Inventar lässt sich ergänzen oder ersetzen. Auf iOS geht das direkt im Teilen-Dialog („Inventar übernehmen“), ohne die App zu öffnen.
- Android und iOS verwenden dasselbe Code-Format. Ein Code vom Android-Handy funktioniert auf dem iPhone und umgekehrt.
