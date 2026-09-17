#!/usr/bin/env sh
# gyeol machine id — a name for this machine that does not move
#
# `hostname` is not that name. A DHCP lease or a VPN rewrites it: an office VPN
# turned one laptop into `ip-172-16-1-2.ap-northeast-2.compute.internal`, and
# over a week the same two machines signed one memory tree under five different
# names. Nothing downstream could then tell two machines apart from one machine
# on two networks — not the commit log, and not the per-machine daily logs that
# keep two machines from colliding on the same file.
#
# Order of preference, first non-empty wins:
#
#   $GYEOL_HOME/.machine-id   an explicit override, one line ("#" comments ignored)
#   macOS                     scutil --get LocalHostName   (survives the network)
#   systemd                   hostnamectl --static
#   anything else             hostname -s                  (may move; last resort)
#
# Prints one line, safe to paste into a filename. Never fails: an install with
# no usable name prints `unknown` rather than an empty string, because an empty
# machine id would silently collapse every machine's daily log back onto one
# path — the exact collision this exists to prevent.

set -u

GYEOL_HOME="${GYEOL_HOME:-$HOME/.config/gyeol}"

id=""

if [ -f "$GYEOL_HOME/.machine-id" ]; then
  id=$(awk 'NF {
    sub(/#.*/, "")
    gsub(/[[:space:]]/, "")
    if ($0 != "") { print; exit }
  }' "$GYEOL_HOME/.machine-id" 2>/dev/null || true)
fi

[ -n "$id" ] || id=$(scutil --get LocalHostName 2>/dev/null || true)
[ -n "$id" ] || id=$(hostnamectl --static 2>/dev/null || true)
[ -n "$id" ] || id=$(hostname -s 2>/dev/null || true)
[ -n "$id" ] || id=unknown

# One token, filename-safe: anything outside [A-Za-z0-9._-] becomes "-".
printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '-'
printf '\n'
