#!/usr/bin/env bash
# Runs INSIDE the sandbox (piped by verify.sh) for the inside kit. Plain MCP over HTTP, no agent needed.
set -u
URL="${1:?usage: mcp-smoke.sh <mcp-url>}"
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"poc","version":"1"}}}'
resp="$(curl -s -i -m 15 -XPOST "$URL" "${H[@]}" -d "$init" | tr -d '\r')"
status="$(echo "$resp" | head -1)"
echo "initialize              : $status"
sid="$(echo "$resp" | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')"
[ -n "$sid" ] || exit 1

curl -s -m 15 -XPOST "$URL" "${H[@]}" -H "Mcp-Session-Id: $sid" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

tools="$(curl -s -m 15 -XPOST "$URL" "${H[@]}" -H "Mcp-Session-Id: $sid" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
echo "tools/list              : $(echo "$tools" | grep -o '"name":"[a-z_0-9]*"' | head -3 | tr '\n' ' ')"

# The first backend call can exceed reShapr's 3s backend timeout: retry before failing.
for attempt in 1 2 3; do
  call="$(curl -s -m 20 -XPOST "$URL" "${H[@]}" -H "Mcp-Session-Id: $sid" \
    -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_v1_forecast","arguments":{"latitude":"48.85","longitude":"2.35","current":"temperature_2m"}}}')"
  echo "tools/call forecast ($attempt/3): $(echo "$call" | cut -c1-140)..."
  echo "$call" | grep -q '"isError":false' && exit 0
  sleep 3
done
exit 1
