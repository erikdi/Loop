#!/bin/bash
# Simple script to update the version in all relevant targets.
# Usage:
#  bash version_update.sh 1.9.4.20190824 1.9.4.20190825

set +e

OLDVERSION="$1"
NEWVERSION="$2"

case "$1" in
    "")
        echo old version is empty
        exit 1;;
    [0-9].[0-9].[0-9].20[1-2][0-9][0-1][0-9][0-3][0-9])
        echo old version is ok;;
    *)
        echo "old version is ok, but non-standard"
esac

case "$2" in
    "")
        echo new version is empty
        exit 2;;
    [0-9].[0-9].[0-9].20[1-2][0-9][0-1][0-9][0-3][0-9])
        echo new version is ok;;
    *)
        echo "new version is not ok"
        exit 2;;
esac

for f in "Loop/Info.plist" "LoopUI/Info.plist" "WatchApp Extension/Info.plist" "WatchApp/Info.plist" "DoseMathTests/Info.plist" "LoopTests/Info.plist" "Loop Status Extension/Info.plist" ; do

	sed -i "" "s/>$OLDVERSION</>$NEWVERSION</" "$f"
	git add "$f"
done

PROJECTVERSION=$(sed -n -E "s/CURRENT_PROJECT_VERSION = ([0-9]+);/\1 + 1/p" Loop.xcodeproj/project.pbxproj | head -n1 | bc)
echo "New project version $PROJECTVERSION"
sed -E -i "" "s/(CURRENT_PROJECT|DYLIB_CURRENT)(_VERSION =)( +[0-9]+)/\1\2 $PROJECTVERSION/" Loop.xcodeproj/project.pbxproj
git add Loop.xcodeproj/project.pbxproj