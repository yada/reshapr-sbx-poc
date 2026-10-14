#!/usr/bin/env bash
# Create a sandbox with the kit, store the API key, and prove the integration.
source "$(dirname "$0")/common.sh"
[ -s "$STATE/api-key" ] || { echo "run scripts/up.sh first"; exit 1; }
fail=0
check() { if "$@"; then echo "  PASS"; else echo "  FAIL"; fail=1; fi; }

# The credential mode (SBX_CRED_RESHAPR_MODE) is fixed at creation: store the key BEFORE creating the sandbox.
"$(dirname "$0")/bind.sh" || exit 1

say "Storing the API key on the host (never enters the sandbox)"
"${SBX[@]}" secret rm reshapr --force >/dev/null 2>&1 || true
"${SBX[@]}" secret set reshapr < "$STATE/api-key" 2>&1 | tail -1

say "Creating sandbox '$SANDBOX' ($BASE + reshapr kit)"
"${SBX[@]}" rm -f "$SANDBOX" >/dev/null 2>&1 || true
"${SBX[@]}" create "$BASE" --name "$SANDBOX" --kit "$ROOT/reshapr" </dev/null 2>&1 | grep -E "Created|WARN|rror" || true

say "1. The agent has the reshapr MCP server registered ($AGENT)"
# claude reports a live connection; codex and copilot only list the registration
# (a live connection would need an LLM login, so step 2 proves the reShapr server path instead).
case "$AGENT" in
  claude)  list="claude mcp list";  ok='reshapr.*Connected' ;;
  codex)   list="codex mcp list";   ok='reshapr.*enabled' ;;
  copilot) list="copilot mcp list"; ok='reshapr' ;;
  *) list=""; echo "  (no registration check for agent '$AGENT')" ;;
esac
if [ -n "$list" ]; then
  "${SBX[@]}" exec "$SANDBOX" $list 2>&1 | grep reshapr || true
  check bash -c "${SBX[*]} exec '$SANDBOX' $list 2>&1 | grep -q '$ok'"
fi

say "2. MCP round trip from inside the sandbox (key injected by the proxy)"
check bash -c "${SBX[*]} exec -i '$SANDBOX' bash -s < '$ROOT/scripts/mcp-smoke.sh'"

say "3. Without the key the reShapr server refuses (401)"
curl -s -o /dev/null -w "  reShapr server status without key (from the host): %{http_code}\n" -m 15 -XPOST "http://localhost:$PORT/mcp/$EXPOSITION" -H "Content-Type: application/json" -d "{}"

say "4. The backend API is only reachable through the reShapr server"
"${SBX[@]}" exec "$SANDBOX" sh -c \
  'curl -s -o /dev/null -w "  direct https://api.open-meteo.com: %{http_code}\n" -m 8 https://api.open-meteo.com/ || true'
echo "  (403 under deny-all; with a permissive daemon policy this line is informational)"

say "Network log for this sandbox"
"${SBX[@]}" policy log "$SANDBOX" 2>&1 | grep -E "localhost:7777|open-meteo" || true

[ "$fail" = 0 ] && say "ALL CHECKS PASSED" || { say "SOME CHECKS FAILED"; exit 1; }
