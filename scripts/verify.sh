#!/usr/bin/env bash
# Create a sandbox with one of the two kits and prove the integration.
#   MODE=outside (default): reShapr on the host, reached through the sbx MCP gateway (needs `make up`)
#   MODE=inside           : reShapr in the sandbox itself (needs nothing on the host)
#   AGENT=claude|codex|copilot (default claude)
source "$(dirname "$0")/common.sh"
MODE="${MODE:-outside}"
fail=0
check() { if "$@"; then echo "  PASS"; else echo "  FAIL"; fail=1; fi; }

case "$AGENT" in
  claude)  list="claude mcp list";  ok='reshapr.*Connected' ;;
  codex)   list="codex mcp list";   ok='reshapr.*enabled' ;;
  copilot) list="copilot mcp list"; ok='reshapr' ;;
  *) echo "unknown AGENT '$AGENT'"; exit 1 ;;
esac

"${SBX[@]}" rm -f "$SANDBOX" >/dev/null 2>&1 || true

if [ "$MODE" = outside ]; then
  [ -s "$STATE/api-key" ] || { echo "run scripts/up.sh first"; exit 1; }
  # The secret must exist BEFORE `sbx mcp add`, and before the sandbox is created.
  say "Registering the reShapr server with the sbx MCP gateway (key stays on the host)"
  "${SBX[@]}" secret rm mcp:reshapr:api-key --force >/dev/null 2>&1 || true
  "${SBX[@]}" secret set mcp:reshapr:api-key < "$STATE/api-key" 2>&1 | tail -1
  "${SBX[@]}" mcp rm reshapr --force >/dev/null 2>&1 || true
  "${SBX[@]}" mcp add reshapr --url "http://localhost:$PORT/mcp/$EXPOSITION" \
    --header 'x-reshapr-key: ${api-key}' --skip-ssrf-check 2>&1 | tail -1
  check bash -c "${SBX[*]} mcp ls | grep -q 'reshapr.*ready'"

  say "Creating sandbox '$SANDBOX' ($BASE + reshapr-outside-sbx kit, --static-mcp reshapr)"
  "${SBX[@]}" create "$BASE" --name "$SANDBOX" --kit "$ROOT/sbx-kits/reshapr-outside-sbx" --static-mcp reshapr </dev/null 2>&1 | grep -E "Created|WARN|rror" || true

  say "1. The agent has the mcp-gateway registered ($AGENT)"
  case "$AGENT" in claude) ok='mcp-gateway.*Connected' ;; codex) ok='mcp-gateway.*enabled' ;; copilot) ok='mcp-gateway' ;; esac
  "${SBX[@]}" exec "$SANDBOX" $list 2>&1 | grep gateway || true
  check bash -c "${SBX[*]} exec '$SANDBOX' $list 2>&1 | grep -q '$ok'"

  say "2. The kit's agent context is installed"
  check bash -c "${SBX[*]} exec '$SANDBOX' sh -c 'grep -rl \"mcp-gateway\" ~/.claude ~/.codex ~/.copilot /home/agent 2>/dev/null | grep -qi reshapr-outside-sbx'"

  say "3. The API key is not in the sandbox"
  key="$(cat "$STATE/api-key")"
  check bash -c "! ${SBX[*]} exec '$SANDBOX' sh -c 'grep -rqF \"$key\" /home/agent /etc /tmp 2>/dev/null'"
else
  say "Creating sandbox '$SANDBOX' ($BASE + reshapr-inside-sbx kit)"
  "${SBX[@]}" create "$BASE" --name "$SANDBOX" --kit "$ROOT/sbx-kits/reshapr-inside-sbx" </dev/null 2>&1 | grep -E "Created|WARN|rror" || true

  say "1. reShapr starts and the API is imported (up to 3 minutes)"
  check bash -c "for _ in \$(seq 90); do [ \"\$(${SBX[*]} exec '$SANDBOX' curl -s -o /dev/null -w '%{http_code}' -XPOST 'http://localhost:7777/mcp/$EXPOSITION' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"v\",\"version\":\"1\"}}}' 2>/dev/null)\" = 200 ] && exit 0; sleep 2; done; exit 1"

  say "2. The agent has the reshapr MCP server registered ($AGENT)"
  "${SBX[@]}" exec "$SANDBOX" $list 2>&1 | grep reshapr || true
  check bash -c "${SBX[*]} exec '$SANDBOX' $list 2>&1 | grep -q '$ok'"

  say "3. MCP round trip from inside the sandbox"
  check bash -c "${SBX[*]} exec -i '$SANDBOX' bash -s -- 'http://localhost:7777/mcp/$EXPOSITION' < '$ROOT/scripts/mcp-smoke.sh'"
fi

say "Network log for this sandbox"
"${SBX[@]}" policy log "$SANDBOX" 2>&1 | grep -E "reshapr|quay|open-meteo|mcp-gateway" | head -10 || true

[ "$fail" = 0 ] && say "ALL CHECKS PASSED" || { say "SOME CHECKS FAILED"; exit 1; }
