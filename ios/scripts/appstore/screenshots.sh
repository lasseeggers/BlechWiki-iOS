#!/bin/zsh
# Nimmt die Screens für den App Store im Simulator auf: Startseite, Suche, Suchergebnisse,
# Buchansicht, Gesangbuch, Inventar. Immer mit Landeskirche Nordelbien und denselben
# 6 Büchern im Inventar, Statusleiste 9:41.
#
#   ios/scripts/appstore/screenshots.sh <Ausgabeordner>
#   SIM="iPad Pro 13-inch (M5)" ios/scripts/appstore/screenshots.sh <Ausgabeordner>
#   SIM="iPhone Duo" DISPLAY_WIDTH=1398 ios/scripts/appstore/screenshots.sh <Ausgabeordner>
#
# Das iPhone Duo hat mehrere Displays, ohne Auswahl ist das Bild schwarz. DISPLAY_WIDTH wählt
# das Display über seine Breite: 1398 außen (zugeklappt), 2007 innen. Die Port-UUIDs ändern
# sich bei jedem Start des Simulators. Aufgeklappt wird nur per Hand in DeviceHub.
#
# Braucht einen Debug-Build, weil nur der die Startparameter BBW_* liest.
set -euo pipefail

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/../.."

OUT=${1:?Ausgabeordner angeben}
SIM_NAME=${SIM:-iPhone 18 Pro}
APP=blechwiki.eggers.media
GROUP=group.blechwiki.eggers.media
mkdir -p "$OUT" build

UDID=$(xcrun simctl list devices available | grep -F "    $SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[[ -n "$UDID" ]] || { echo "Simulator \"$SIM_NAME\" nicht gefunden" >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
DISPLAY_PORT=
if [[ -n "${DISPLAY_WIDTH:-}" ]]; then
  DISPLAY_PORT=$(xcrun simctl io "$UDID" enumerate | awk -v w="$DISPLAY_WIDTH" '/UUID:/ {u=$2} $0 ~ "Default width: " w "$" {print u; exit}')
  [[ -n "$DISPLAY_PORT" ]] || { echo "Kein Display mit Breite $DISPLAY_WIDTH" >&2; exit 1; }
fi

echo "Simulator $SIM_NAME ($UDID), baue Debug"
xcodebuild -project BetterBlechWiki.xcodeproj -scheme BetterBlechWiki -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build/SimData build > build/sim.log 2>&1 || {
  grep -E 'error:' build/sim.log | sort -u >&2
  echo "Build fehlgeschlagen, Log: ios/build/sim.log" >&2
  exit 1
}
xcrun simctl install "$UDID" build/SimData/Build/Products/Debug-iphonesimulator/BlechWiki.app

# Inventar und Landeskirche fest vorgeben, damit die Bilder bei jedem Lauf gleich aussehen. Über die
# Startparameter der Debug-App: Eine direkt geschriebene Einstellungsdatei übergeht der Simulator, wenn
# er die Werte vom letzten Lauf noch im Speicher hat.
# Buch-IDs der REST-API (seit 0.7.0): Himmel Erde Luft und Meer, Norddeutsches Bläserheft 3, 4,
# Norddeutsches Bläserheft (2010), Bläserheft 2026 Bayern, Norddeutsches Bläserheft 5.
# Derselbe Inventar-Code zum Einfügen per Hand: BBW-0W90-2ERM-JB5J-N591-SMDX-VA7D-WVP8
export SIMCTL_CHILD_BBW_OWNED=1541,1681,1905,390,5050,5084 SIMCTL_CHILD_BBW_APPENDIX=N
xcrun simctl terminate "$UDID" "$APP" 2>/dev/null || true
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$APP" "$GROUP")

xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --dataNetwork wifi

launch() { xcrun simctl launch --terminate-running-process "$UDID" "$APP" >/dev/null; }
shot() { sleep "${WAIT:-6}"; xcrun simctl io "$UDID" screenshot ${DISPLAY_PORT:+--display=$DISPLAY_PORT} "$OUT/$1.png" >/dev/null 2>&1 && echo "$1"; }

# Beim ersten Start lädt die App das Verzeichnis und die Inhalte der 6 Bücher
if [[ ! -s "$CONTAINER/blechwiki.sqlite" ]]; then
  echo "Erster Start, lade Daten (bis 3 Minuten)"
  launch
  for i in {1..90}; do [[ -s "$CONTAINER/blechwiki.sqlite" ]] && break; sleep 2; done
  sleep 30
fi

# Inventar setzen und die Bücher laden lassen, sonst fehlt "alle offline verfügbar"
launch; sleep 20
L="Lobe den Herren, den mächtigen König der Ehren"
launch; WAIT=8 shot startseite
SIMCTL_CHILD_BBW_QUERY="lob herr" launch; shot suche
SIMCTL_CHILD_BBW_OPEN=eg:859 SIMCTL_CHILD_BBW_LABEL="$L" SIMCTL_CHILD_BBW_DETAIL="EG 316" launch; shot suchergebnisse
# Zwei Spalten (iPad, Mac, Duo innen): Treffer links, Suchergebnisse rechts. Auf dem iPhone wie suchergebnisse
SIMCTL_CHILD_BBW_QUERY="lobe den herren" SIMCTL_CHILD_BBW_OPEN=eg:859 SIMCTL_CHILD_BBW_LABEL="$L" SIMCTL_CHILD_BBW_DETAIL="EG 316" launch; shot zwei-spalten
SIMCTL_CHILD_BBW_OPEN="book:5084" SIMCTL_CHILD_BBW_LABEL="Norddeutsches Bläserheft 5" SIMCTL_CHILD_BBW_DETAIL="2026" launch; shot buch
SIMCTL_CHILD_BBW_OPEN=hymnal launch; shot gesangbuch
SIMCTL_CHILD_BBW_OPEN=mybooks launch; shot inventar

xcrun simctl status_bar "$UDID" clear
echo "Fertig: $(sips -g pixelWidth -g pixelHeight "$OUT/startseite.png" | awk '/pixel/{print $2}' | xargs | tr ' ' x) in $OUT"
