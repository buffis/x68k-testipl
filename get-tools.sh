#!/bin/sh
# Fetch and build the toolchain into tools/: vasm (assembler), vbcc (C
# compiler) and vlink (linker), all m68k, all from Frank Wille's sources.
# build.py picks them up from there automatically.
set -e
cd "$(dirname "$0")"
mkdir -p tools
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fetch () { echo "downloading $1..."; curl -sL -o "$TMP/$1.tar.gz" "$2"; tar xzf "$TMP/$1.tar.gz" -C "$TMP"; }

fetch vasm  http://sun.hasenbraten.de/vasm/release/vasm.tar.gz
fetch vlink http://sun.hasenbraten.de/vlink/release/vlink.tar.gz
fetch vbcc  http://www.ibaug.de/vbcc/vbcc.tar.gz

echo "building vasm..."
make -C "$TMP/vasm" CPU=m68k SYNTAX=mot >/dev/null 2>&1
cp "$TMP/vasm/vasmm68k_mot" tools/

echo "building vlink..."
make -C "$TMP/vlink" >/dev/null 2>&1
cp "$TMP/vlink/vlink" tools/

# vbcc's dtgen asks which host types implement each target type.  The defaults
# are correct for a 64-bit Linux host, so feed it empty lines -- NOT "yes y",
# which answers the type questions with the literal string "y" and produces a
# dt.h full of "((y)(x))" casts that fail to compile.  With no stdin at all it
# loops on EOF forever.
echo "building vbcc..."
mkdir -p "$TMP/vbcc/bin"
( cd "$TMP/vbcc" && yes '' | make TARGET=m68k ) >/dev/null 2>&1
cp "$TMP/vbcc/bin/vbccm68k" tools/

echo "installed in $(pwd)/tools:"
tools/vasmm68k_mot 2>&1 | head -1
tools/vbccm68k 2>&1 | grep -i vbcc | head -1 || echo "  vbccm68k"
tools/vlink -h 2>&1 | head -1
