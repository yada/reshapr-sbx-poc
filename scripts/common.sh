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

# v3 source kits are built in a builder sandbox; the host-docker path fails on
# Docker Desktop's classic image store (OCI exporter not supported).
export SBX_KIT_BUILDER="${SBX_KIT_BUILDER:-sandbox}"

# v3 mixins need a v3 workload as base. The built-in `claude` and `codex` names
# don't compose with them; the published workloads do. Pinned on purpose.
# Copilot uses the built-in name: with the published v3 workload the `github`
# token is not injected (Copilot fails with "Bad credentials").
case "$AGENT" in
  claude)  BASE="docker.io/docker/sbx-kit-claude:2.1.296" ;;
  codex)   BASE="docker.io/docker/sbx-kit-codex:0.162.1" ;;
  copilot) BASE="copilot" ;;
  *)       BASE="$AGENT" ;;
esac
export BASE

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
