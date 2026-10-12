#!/usr/bin/env bash
# Remove the sandbox, its secret, the reShapr stack and local state.
source "$(dirname "$0")/common.sh"
"${SBX[@]}" secret rm reshapr --force >/dev/null 2>&1 || true
"${SBX[@]}" rm -f "$SANDBOX" >/dev/null 2>&1 || true
[ -e "$STATE/created-binding" ] && rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/sbx/credentials.yaml"
reshapr stop || true
# .state holds the CLI session, compose files and the Postgres data (HOME is redirected)
rm -rf "$STATE"
say "Cleaned up"
