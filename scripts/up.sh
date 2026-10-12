#!/usr/bin/env bash
# Start reShapr on the host and publish the demo API behind an API key.
source "$(dirname "$0")/common.sh"
mkdir -p "$STATE/home"

say "Starting reShapr $RELEASE with 'reshapr run' (control plane :5555, MCP server :7777${UI:+, web UI :3333})"
reshapr run -r "$RELEASE" ${UI:+--ui} >/dev/null
for p in 5555 7777; do
  for _ in $(seq 60); do curl -sf "http://localhost:$p/q/health/ready" >/dev/null && continue 2; sleep 2; done
  echo "reShapr did not become ready on :$p"; exit 1
done

say "Logging in to the control plane"
reshapr login -s http://localhost:5555 -u admin -p password >/dev/null

if [ -s "$STATE/api-key" ]; then
  say "Open-Meteo already imported (key in .state/api-key)"
else
  say "Importing Open-Meteo as an MCP server (API key + audit log on)"
  out="$(reshapr import \
    -u https://raw.githubusercontent.com/open-meteo/open-meteo/refs/heads/main/openapi/forecast.yml \
    --backendEndpoint https://api.open-meteo.com --apiKey --audit 2>&1)"
  echo "$out" | grep -E "Endpoints|Exposition Name" || true
  key="$(echo "$out" | sed -n 's/.*API Key to access future expositions is: //p' | tr -d '[:space:]')"
  [ -n "$key" ] || { echo "could not read the API key:"; echo "$out"; exit 1; }
  umask 077; printf '%s' "$key" > "$STATE/api-key"
fi

[ -z "${UI:-}" ] || say "Web UI: http://localhost:3333  (admin / password)"
say "Ready: http://localhost:7777/mcp/$EXPOSITION"
