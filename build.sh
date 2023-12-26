#!/usr/bin/env bash

if ! type jq &> /dev/null; then echo 'jq command required and not found, exiting'; exit 1; fi

NAME_VER="$(jq -r '.name + "_" + .version' info.json)"

rm -r target
mkdir -p "target/$NAME_VER"
cp -r locale *.lua *.md *.txt *.json *.png LICENSE "target/$NAME_VER"

cd target || exit 1
zip -r $NAME_VER.zip $NAME_VER
echo "Zipfile created: $NAME_VER"
