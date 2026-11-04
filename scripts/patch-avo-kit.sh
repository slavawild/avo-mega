#!/bin/sh
# Applies Avo's patches to the pinned avo_kit checkout (vendor/avo_kit),
# in name order, for `make build`, `make test` and CI alike, until avo_kit
# takes them upstream:
#
#   0001  Swift 6.3 crashes diagnosing one closure in KeymapEditorView.
#
# A patch already applied is left alone, so this runs before every build.
# One that neither applies nor is applied means avo_kit changed: drop it
# (or redo it) then.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KIT="$ROOT/vendor/avo_kit"

for patch in "$ROOT"/scripts/avo-kit-patches/*.patch; do
    name=$(basename "$patch")
    if git -C "$KIT" apply --reverse --check "$patch" 2>/dev/null; then
        continue
    fi
    if ! git -C "$KIT" apply --check "$patch" 2>/dev/null; then
        echo "avo_kit no longer takes $name: avo_kit changed, so drop or redo it (scripts/avo-kit-patches)" >&2
        exit 1
    fi
    git -C "$KIT" apply "$patch"
    echo "avo_kit: applied $name"
done
