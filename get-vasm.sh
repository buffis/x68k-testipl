#!/bin/sh
# Fetch and build vasm (m68k, Motorola syntax) into post/tools/.
# build.py picks it up from there automatically, so this is all that is needed
# to make the project buildable on a fresh machine.
set -e
cd "$(dirname "$0")"
mkdir -p tools
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "downloading vasm..."
curl -sL -o "$TMP/vasm.tar.gz" http://sun.hasenbraten.de/vasm/release/vasm.tar.gz
tar xzf "$TMP/vasm.tar.gz" -C "$TMP"
echo "building..."
make -C "$TMP/vasm" CPU=m68k SYNTAX=mot >/dev/null 2>&1
cp "$TMP/vasm/vasmm68k_mot" tools/
echo "installed: $(pwd)/tools/vasmm68k_mot"
tools/vasmm68k_mot 2>&1 | head -2 || true
