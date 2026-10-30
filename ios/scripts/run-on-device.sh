#!/bin/zsh
# Baut die App, signiert sie mit dem eigenen Apple-Account und startet sie auf dem
# per USB angeschlossenen iPhone.
#
#   ios/scripts/run-on-device.sh            Debug-Build
#   CONFIG=Release ios/scripts/run-on-device.sh
#
# Voraussetzung: Apple-Account in Xcode › Einstellungen › Accounts angemeldet (kostenloser
# Account reicht, Apps laufen dann 7 Tage). Team-ID wird aus dem Zertifikat gelesen oder
# per TEAM=XXXXXXXXXX vorgegeben.
set -euo pipefail

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-Debug}
BUNDLE_ID=blechwiki.eggers.media

if [[ -z "${TEAM:-}" ]]; then
  # OU im Zertifikat "Apple Development: …" ist die Team-ID
  TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)
fi
if [[ -z "$TEAM" ]]; then
  echo "Kein Signierzertifikat gefunden. Xcode öffnen › Einstellungen › Accounts › Apple-Account hinzufügen," >&2
  echo "dann einmal 'Manage Certificates…' › '+' › 'Apple Development'. Oder TEAM=… setzen." >&2
  exit 1
fi

# Per USB verbundene Geräte zuerst, sonst ein gekoppeltes im selben WLAN ("available (paired)")
device_with() {
  xcrun devicectl list devices 2>/dev/null | awk -v state="$1" '/physical/ && $0 ~ state {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1
}
DEVICE=${DEVICE:-$(device_with connected)}
DEVICE=${DEVICE:-$(device_with available)}
if [[ -z "$DEVICE" ]]; then
  echo "Kein iPhone gefunden. Per USB anschließen, entsperren und 'Diesem Computer vertrauen' bestätigen." >&2
  exit 1
fi

echo "Team $TEAM, Gerät $DEVICE, $CONFIG"
mkdir -p build
xcodebuild -project BetterBlechWiki.xcodeproj -scheme BetterBlechWiki -configuration "$CONFIG" \
  -destination "id=$DEVICE" -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" build > build/xcodebuild.log 2>&1 || {
  grep -E 'error:' build/xcodebuild.log | sort -u >&2
  echo "Build fehlgeschlagen, Log: ios/build/xcodebuild.log" >&2
  exit 1
}
grep -E 'warning:' build/xcodebuild.log | grep -v appintents | sort -u || true

APP="build/DerivedData/Build/Products/$CONFIG-iphoneos/BetterBlechWiki.app"
[[ -d "$APP" ]] || { echo "Build fehlgeschlagen" >&2; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" \
  || echo "Start fehlgeschlagen. Beim ersten Mal am iPhone: Einstellungen › Allgemein › VPN & Geräteverwaltung › Entwickler-App vertrauen, und Entwicklermodus einschalten."
