#!/usr/bin/env bash
# Shared settings. Source me.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/.state"
SANDBOX="${SANDBOX:-reshapr-poc}"
AGENT="${AGENT:-claude}"
PORT="${PORT:-7777}"
EXPOSITION="${EXPOSITION:-reshapr/open-meteo-weather-forecast-api-1-0-default}"
RELEASE="${RESHAPR_RELEASE:-1.0.0}"   # reShapr release for `reshapr run -r` and the CLI

# SBX_APP=<name> runs everything on an isolated sbx daemon (own policy,
# secrets, sandboxes). It needs a one-time `sbx --app-name <name> login`.
if [ -n "${SBX_APP:-}" ]; then SBX=(sbx --app-name "$SBX_APP"); else SBX=(sbx); fi

# The reshapr CLI keeps its session and the stack data in $HOME/.reshapr and $HOME/tmp;
# point HOME at .state so the POC never touches the real ones. Uses the globally installed CLI
# (npm i -g @reshapr/reshapr-cli --allow-scripts=@scarf/scarf), else npx at the pinned release.
# DOCKER_CONFIG keeps the real docker context/credentials despite the HOME override.
reshapr() {
  local env=(HOME="$STATE/home" DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}")
  if command -v reshapr >/dev/null 2>&1; then env "${env[@]}" reshapr "$@"
  else env "${env[@]}" npx --yes "@reshapr/reshapr-cli@$RELEASE" "$@"; fi
}

say() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
