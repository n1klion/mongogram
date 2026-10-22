#!/bin/bash
# Regenerates the README screenshots in docs/images from the sample schemas.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product MongoGram
BIN="$(swift build --show-bin-path)/MongoGram"
mkdir -p docs/images

shot() {  # shot <output> <schema> [ENV=value ...]
  local out=$1 schema=$2; shift 2
  env MONGOGRAM_SCREENSHOT="$PWD/docs/images/$out" "$@" "$BIN" "$schema" >/dev/null 2>&1
  echo "docs/images/$out"
}

shot overview-dark.png      samples/shop.dmm   MONGOGRAM_APPEARANCE=dark  MONGOGRAM_SELECT_TABLE=orders
shot relationship-light.png samples/shop.dmm   MONGOGRAM_APPEARANCE=light MONGOGRAM_SELECT_REF=orders.customerId
shot subdiagram-light.png   samples/shop.dmm   MONGOGRAM_APPEARANCE=light MONGOGRAM_DIAGRAM=Catalog MONGOGRAM_SELECT_TABLE=products
