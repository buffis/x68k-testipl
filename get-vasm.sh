#!/bin/sh
# Renamed: the toolchain is now vasm + vbcc + vlink.  See get-tools.sh.
exec "$(dirname "$0")/get-tools.sh" "$@"
