#!/bin/zsh
# Wandelt die PNG-Exporte aus Claude Design in Dateien um, die App Store Connect annimmt:
# JPG ohne Alphakanal in den Pflichtgrößen. Prüft danach jede Datei.
#
#   ios/scripts/appstore/convert.sh <Ordner mit den Exporten> <Zielordner>
#
# Erwartete Exporte (Namen wie Claude Design sie vergibt, Endung @1x.png):
#   "1 Suchergebnisse" … "5 Gesangbuch" 1320×2868
#   "iPad 1 Suchergebnisse" …           2064×2752
#   "Duo 1 Suchergebnisse" …            1398×2034 (iPhone Duo außen)
#   "Kopfzeile …"                       3840×1646
#   "Suchergebnis …"                    3840×2560
set -euo pipefail

SRC=${1:?Exportordner angeben}
DST=${2:?Zielordner angeben}
MID="$DST/iPhone Dynamic Island mittel 1206x2622"
LARGE="$DST/iPhone Dynamic Island gross 1320x2868"
PAGE="$DST/Produktseite"
IPAD="$DST/iPad 13 Zoll 2064x2752"
DUO="$DST/iPhone Duo aussen 1398x2034"
mkdir -p "$MID" "$LARGE" "$PAGE" "$IPAD" "$DUO"

size() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixel/{print $2}' | xargs | tr ' ' x; }
jpg() { sips -s format jpeg -s formatOptions 95 "$@" >/dev/null; }

found=0
for f in "$SRC"/[1-9]\ *@1x.png(N); do
  name=${${f:t}%@1x.png}
  [[ $(size "$f") == 1320x2868 ]] || { echo "Übersprungen, nicht 1320x2868: ${f:t}" >&2; continue; }
  jpg "$f" --out "$LARGE/$name.jpg"
  jpg -z 2622 1206 "$f" --out "$MID/$name.jpg"
  found=$((found + 1))
done
# Weitere Geräte: Name ohne Gerätepräfix, damit die Dateien wie beim iPhone "1 Suchergebnisse.jpg" heißen
for f in "$SRC"/iPad\ [1-9]\ *@1x.png(N) "$SRC"/Duo\ [1-9]\ *@1x.png(N); do
  name=${${${f:t}%@1x.png}#* }
  case "${f:t}:$(size "$f")" in
    iPad*:2064x2752) jpg "$f" --out "$IPAD/$name.jpg" ;;
    Duo*:1398x2034) jpg "$f" --out "$DUO/$name.jpg" ;;
    *) echo "Übersprungen, unerwartete Größe $(size "$f"): ${f:t}" >&2; continue ;;
  esac
  found=$((found + 1))
done
for f in "$SRC"/Kopfzeile*@1x.png(N) "$SRC"/Suchergebnis\ *@1x.png(N); do
  case $(size "$f") in
    3840x1646) jpg "$f" --out "$PAGE/Kopfzeile 3840x1646.jpg" ;;
    3840x2560) jpg "$f" --out "$PAGE/Suchergebnis 3840x2560.jpg" ;;
    *) echo "Übersprungen, unbekannte Größe $(size "$f"): ${f:t}" >&2 ;;
  esac
done
(( found > 0 )) || echo "Keine Screenshots gefunden (erwartet: \"1 Suchergebnisse@1x.png\" …)" >&2

# Prüfung: Größe passt zum Ordner, kein Alphakanal
bad=0
for f in "$DST"/*/*.jpg(N); do
  s=$(size "$f"); a=$(sips -g hasAlpha "$f" | awk '/hasAlpha/{print $2}')
  want=$(echo "${f:h:t} ${f:t}" | grep -oE '[0-9]{4}x[0-9]{4}' | tail -1)
  if [[ "$s" != "$want" || "$a" != no ]]; then echo "FEHLER ${f:h:t}/${f:t}: $s, Alpha $a" >&2; bad=1
  else echo "ok ${f:h:t}/${f:t}"; fi
done
exit $bad
