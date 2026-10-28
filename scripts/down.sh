#!/usr/bin/env bash
# Remove the sandboxes, the gateway registration, its secrets, the reShapr stack and local state.
source "$(dirname "$0")/common.sh"
"${SBX[@]}" rm -f "$SANDBOX" >/dev/null 2>&1 || true
"${SBX[@]}" mcp rm reshapr --force >/dev/null 2>&1 || true
"${SBX[@]}" secret rm mcp:reshapr:api-key --force >/dev/null 2>&1 || true
"${SBX[@]}" secret rm mcp:reshapr:api-key:endpoint --force >/dev/null 2>&1 || true
reshapr stop || true
# .state holds the CLI session, compose files and the Postgres data (HOME is redirected)
rm -rf "$STATE"
say "Cleaned up"
