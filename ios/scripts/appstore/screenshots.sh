#!/bin/zsh
# Nimmt die Screens für den App Store im Simulator auf: Startseite, Suche, Suchergebnisse,
# Buchansicht, Gesangbuch, Inventar. Immer mit Landeskirche Nordelbien und denselben
# 6 Büchern im Inventar, Statusleiste 9:41.
#
#   ios/scripts/appstore/screenshots.sh <Ausgabeordner>
#   SIM="iPhone Duo" ios/scripts/appstore/screenshots.sh <Ausgabeordner>
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

echo "Simulator $SIM_NAME ($UDID), baue Debug"
xcodebuild -project BetterBlechWiki.xcodeproj -scheme BetterBlechWiki -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build/SimData build > build/sim.log 2>&1 || {
  grep -E 'error:' build/sim.log | sort -u >&2
  echo "Build fehlgeschlagen, Log: ios/build/sim.log" >&2
  exit 1
}
xcrun simctl install "$UDID" build/SimData/Build/Products/Debug-iphonesimulator/BetterBlechWiki.app

# Inventar und Landeskirche fest vorgeben, damit die Bilder bei jedem Lauf gleich aussehen
xcrun simctl terminate "$UDID" "$APP" 2>/dev/null || true
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$APP" "$GROUP")
PLIST="$CONTAINER/Library/Preferences/$GROUP.plist"
mkdir -p "${PLIST:h}"
cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>eg_appendix</key><string>N</string>
	<key>migrated_to_app_group</key><true/>
	<key>owned_books</key>
	<array>
		<string>BläshBay26</string>
		<string>HimmelErdeLuftMeer</string>
		<string>Nordd1</string>
		<string>Nordd3</string>
		<string>Nordd4</string>
		<string>Nordd5</string>
	</array>
</dict>
</plist>
EOF

xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --dataNetwork wifi

launch() { xcrun simctl launch --terminate-running-process "$UDID" "$APP" >/dev/null; }
shot() { sleep "${WAIT:-6}"; xcrun simctl io "$UDID" screenshot "$OUT/$1.png" >/dev/null 2>&1 && echo "$1"; }

# Beim ersten Start lädt die App das Verzeichnis und die Inhalte der 6 Bücher
if [[ ! -s "$CONTAINER/blechwiki.sqlite" ]]; then
  echo "Erster Start, lade Daten (bis 3 Minuten)"
  launch
  for i in {1..90}; do [[ -s "$CONTAINER/blechwiki.sqlite" ]] && break; sleep 2; done
  sleep 30
fi

L="Lobe den Herren, den mächtigen König der Ehren"
launch; WAIT=8 shot startseite
SIMCTL_CHILD_BBW_QUERY="lob herr" launch; shot suche
SIMCTL_CHILD_BBW_OPEN=eg:859 SIMCTL_CHILD_BBW_LABEL="$L" SIMCTL_CHILD_BBW_DETAIL="EG 316" launch; shot suchergebnisse
SIMCTL_CHILD_BBW_OPEN="book:Nordd5" SIMCTL_CHILD_BBW_LABEL="Norddeutsches Bläserheft 5" SIMCTL_CHILD_BBW_DETAIL="2026" launch; shot buch
SIMCTL_CHILD_BBW_OPEN=hymnal launch; shot gesangbuch
SIMCTL_CHILD_BBW_OPEN=mybooks launch; shot inventar

xcrun simctl status_bar "$UDID" clear
echo "Fertig: $(sips -g pixelWidth -g pixelHeight "$OUT/startseite.png" | awk '/pixel/{print $2}' | xargs | tr ' ' x) in $OUT"
