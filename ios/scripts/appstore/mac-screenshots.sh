#!/bin/zsh
# Nimmt die Mac-Fenster für den App Store auf: Suchergebnisse in zwei Spalten, Inventar, Buchansicht,
# Gesangbuch. Fenster 1440 × 900, Landeskirche Nordelbien, dieselben 6 Bücher wie in screenshots.sh.
#
#   ios/scripts/appstore/mac-screenshots.sh <Ausgabeordner>
#
# Braucht für das Terminal bzw. die Entwicklungsumgebung die Freigabe „Bildschirmaufnahme“. Baut die
# Debug-App mit Team-Signatur (nur die liest die Startparameter BBW_*). Auf einem Display mit Faktor 1
# ist jede Aufnahme 1440 × 900, auf Retina 2880 × 1800, beides nimmt App Store Connect an.
set -euo pipefail

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/../.."

OUT=${1:?Ausgabeordner angeben}
mkdir -p "$OUT" build
APP=build/macsigned/Build/Products/Debug-maccatalyst/BlechWiki.app
BIN=$APP/Contents/MacOS/BlechWiki

echo "Baue Debug für Mac Catalyst"
xcodebuild -project BetterBlechWiki.xcodeproj -scheme BetterBlechWiki -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build/macsigned \
  -allowProvisioningUpdates build > build/mac.log 2>&1 || {
  grep -E 'error:' build/mac.log | sort -u >&2
  echo "Build fehlgeschlagen, Log: ios/build/mac.log" >&2
  exit 1
}

# Fenster-ID des Prozesses für screencapture -l
window() {
  swift -e "import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
if let w = l.first(where: { (\$0[kCGWindowOwnerPID as String] as? Int) == $1 && (\$0[kCGWindowLayer as String] as? Int) == 0 }) { print(w[kCGWindowNumber as String]!) }" 2>/dev/null
}

# shot <Name> [VAR=Wert …]: startet die App mit den Startparametern, holt sie nach vorn
# (sonst wirkt das Fenster inaktiv und blass) und nimmt das Fenster ohne Schatten auf
shot() {
  local name=$1; shift
  pkill -f "macsigned.*MacOS/BlechWiki" 2>/dev/null || true
  sleep 1
  env "$@" BBW_OWNED=1541,1681,1905,390,5050,5084 BBW_APPENDIX=N BBW_WINDOW=1440x900 "$BIN" >/dev/null 2>&1 &
  local pid=$!
  sleep "${WAIT:-8}"
  # Zweimal: Kurz nach dem Start übernimmt macOS die Aktivierung nicht immer
  open "$APP"; sleep 2; open "$APP"; sleep 2
  screencapture -x -o -l"$(window "$pid")" "$OUT/$name.png"
  echo "$name $(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" | awk '/pixel/{print $2}' | xargs | tr ' ' x)"
}

# Aufwärmen ohne Aufnahme: Inventar setzen und die Bücher laden lassen. Beim ersten Start kommt das
# Fenster außerdem nicht zuverlässig nach vorn.
WAIT=30 shot aufwaermen BBW_OPEN=mybooks
rm -f "$OUT/aufwaermen.png"

L="Lobe den Herren, den mächtigen König der Ehren"
shot inventar BBW_OPEN=mybooks
shot zwei-spalten BBW_QUERY="lobe den herren" BBW_OPEN=eg:859 BBW_LABEL="$L" BBW_DETAIL="EG 316"
shot buch BBW_OPEN=book:5084 BBW_LABEL="Norddeutsches Bläserheft 5" BBW_DETAIL=2026
shot gesangbuch BBW_OPEN=hymnal
pkill -f "macsigned.*MacOS/BlechWiki" 2>/dev/null || true
echo "Fertig in $OUT"
