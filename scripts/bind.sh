#!/usr/bin/env bash
# sbx only injects a credential into domains the USER allows (~/.config/sbx/credentials.yaml).
# This creates that file ONLY if it does not exist yet; down.sh removes it again.
source "$(dirname "$0")/common.sh"
f="${XDG_CONFIG_HOME:-$HOME/.config}/sbx/credentials.yaml"
if [ -e "$f" ]; then
  grep -q '^  reshapr:' "$f" || { echo "Add this to $f yourself:"; printf 'bindings:\n  reshapr:\n    discovery: []\n    allowedDomains: [localhost]\n'; exit 1; }
  exit 0
fi
mkdir -p "$(dirname "$f")" "$STATE"
printf 'bindings:\n  reshapr:\n    discovery: []\n    allowedDomains:\n      - localhost\n' > "$f"
touch "$STATE/created-binding"
say "Created $f (binding: reshapr -> localhost)"
