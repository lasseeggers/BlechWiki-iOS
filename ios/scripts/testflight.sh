#!/bin/zsh
# Archiviert die App als Release, signiert sie für den App Store und lädt sie zu App Store
# Connect hoch. Danach taucht der Build nach einigen Minuten in TestFlight auf.
#
#   ios/scripts/testflight.sh               Build-Nummer = Anzahl der Commits
#   FORCE=1 ios/scripts/testflight.sh       auch mit nicht committeten Änderungen hochladen
#   BUILD=42 ios/scripts/testflight.sh
#   UPLOAD=0 ios/scripts/testflight.sh      nur .ipa nach ios/build/export-ios, kein Upload
#   PLATFORM=mac ios/scripts/testflight.sh  Mac-Catalyst-Build (.pkg) statt iOS
#
# Voraussetzung: In Xcode › Einstellungen › Accounts ist ein Apple-Account angemeldet, der im
# Team aus DEVELOPMENT_TEAM mindestens App Manager mit Zugriff auf Zertifikate ist. Profile und
# das Distribution-Zertifikat legt xcodebuild über -allowProvisioningUpdates selbst an.
set -euo pipefail

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."

# Jeder Upload braucht eine höhere Build-Nummer als der vorige, die Commit-Anzahl steigt mit.
# Ein zweiter Upload vom selben Commit braucht deshalb einen neuen Commit oder BUILD=…
BUILD=${BUILD:-$(git rev-list --count HEAD)}
UPLOAD=${UPLOAD:-1}
# Gleiche App in App Store Connect, aber eigenes Archiv je Plattform
PLATFORM=${PLATFORM:-ios}
case $PLATFORM in
  ios) DESTINATION_ARCHIVE='generic/platform=iOS' ;;
  mac) DESTINATION_ARCHIVE='generic/platform=macOS,variant=Mac Catalyst' ;;
  *) echo "PLATFORM muss ios oder mac sein" >&2; exit 1 ;;
esac
TEAM=$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]\{10\}\);.*/\1/p' BetterBlechWiki.xcodeproj/project.pbxproj | sort -u)
[[ -n $TEAM && $(echo "$TEAM" | wc -l) -eq 1 ]] || { echo "Kein oder kein einheitliches DEVELOPMENT_TEAM: ${TEAM:-leer}" >&2; exit 1; }

# Sonst gehört der hochgeladene Build zu keinem Commit, und die Build-Nummer passt zu einem anderen Stand
if [[ -n "$(git status --porcelain)" ]]; then
  if [[ "$UPLOAD" == 1 && "${FORCE:-0}" != 1 ]]; then
    echo "Arbeitskopie hat nicht committete Änderungen. Erst committen oder FORCE=1 setzen." >&2
    exit 1
  fi
  echo "Hinweis: Arbeitskopie hat nicht committete Änderungen, die im Build landen." >&2
fi

ARCHIVE=build/BlechWiki-$PLATFORM.xcarchive
EXPORT=build/export-$PLATFORM
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p build

echo "Team $TEAM, Build $BUILD, $PLATFORM"
xcodebuild -project BetterBlechWiki.xcodeproj -scheme BetterBlechWiki -configuration Release \
  -destination "$DESTINATION_ARCHIVE" -archivePath "$ARCHIVE" -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" archive > build/archive-$PLATFORM.log 2>&1 || {
  { grep -E 'error:' build/archive-$PLATFORM.log || true; } | sort -u >&2
  echo "Archiv fehlgeschlagen, Log: ios/build/archive-$PLATFORM.log" >&2
  exit 1
}

[[ "$UPLOAD" == 1 ]] && DESTINATION=upload || DESTINATION=export
cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$DESTINATION</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates > build/export-$PLATFORM.log 2>&1 || {
  { grep -E 'error|Error' build/export-$PLATFORM.log || true; } | sort -u >&2
  echo "Export/Upload fehlgeschlagen, Log: ios/build/export-$PLATFORM.log" >&2
  exit 1
}

if [[ "$UPLOAD" == 1 ]]; then
  echo "Hochgeladen. Build $BUILD erscheint nach der Verarbeitung in App Store Connect › TestFlight."
else
  echo "Paket liegt in ios/$EXPORT"
fi
