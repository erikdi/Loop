#!/bin/bash
# Simple script to update the version in all relevant targets.
# Usage:
#  bash version_update.sh 1.9.4.20190824 1.9.4.20190825

set +e

OLDVERSION="$1"
NEWVERSION="$2"

if [ "$NEWVERSION" == "" ]; then
   NEWVERSION="$OLDVERSION"
   OLDVERSION=$(egrep -o '\d+\.\d+\.\d+' Loop.xcconfig)
   echo "Automatically set old version $OLDVERSION"
   if [ "$NEWVERSION" == "" ]; then
	NEWVERSION=$OLDVERSION.$(date +%Y%m%d)
	echo "Automatically set new version $NEWVERSION"
   fi
fi

case "$NEWVERSION" in
    "")
	echo "new version cannot be empty"
	exit 2;;
    [0-9].[0-9].[0-9].20[1-2][0-9][0-1][0-9][0-3][0-9])
        echo new version is ok;;
    *)
        echo "new version is not ok"
        exit 2;;
esac

case "$OLDVERSION" in
    "")
	echo "old version cannot be empty"
	exit 3;;
    [0-9].[0-9].[0-9].20[1-2][0-9][0-1][0-9][0-3][0-9])
        echo old version is ok;;
    *)
        echo "old version is ok, but non-standard"
esac

for f in "Loop.xcconfig"; do

	sed -i "" "s/LOOP_MARKETING_VERSION = .*/LOOP_MARKETING_VERSION = $NEWVERSION/" "$f"
	git add "$f"
done

PROJECTVERSION=$(sed -n -E "s/CURRENT_PROJECT_VERSION = ([0-9]+);/\1 + 1/p" Loop.xcodeproj/project.pbxproj | head -n1 | bc)
echo "New project version $PROJECTVERSION"
sed -E -i "" "s/(CURRENT_PROJECT|DYLIB_CURRENT)(_VERSION =)( +[0-9]+)/\1\2 $PROJECTVERSION/" Loop.xcodeproj/project.pbxproj
git add Loop.xcodeproj/project.pbxproj
git commit -m "Update to version v$NEWVERSION.$PROJECTVERSION"
git tag "v$NEWVERSION.$PROJECTVERSION"
