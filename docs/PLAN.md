# Design notes: reShapr ⇄ Docker Sandboxes (sbx)

Why this POC exists, what was verified, and what is left. Tested with sbx 0.47.0 and reShapr 1.0.0.

## 1. Why they fit

| | sbx | reShapr |
|---|---|---|
| Question answered | "What can the agent reach / see?" | "What can the agent *do* with an API, and how much comes back?" |
| Boundary | microVM, egress allow-list, host-side credential injection | reShapr server: operation include/exclude, output filters, secrets, API-key/OAuth2, audit |
| Weak spot | Each API needs its own MCP server and allow-list entry | Needs a trustworthy client environment and a way to hold the client credential |

Combined: the agent talks to **one allow-listed host:port**. Backend credentials and hostnames stay on the
reShapr server (host side), and the sbx proxy injects the single reShapr key, so the sandbox never holds it.

## 2. What the kit relies on

**reShapr**
- The reShapr server (:7777) serves MCP over HTTP at `/mcp/<org>/<exposition-name>` (also `/mcp/<expositionId>`).
- Per Configuration Plan, auth is an API key (header `x-reshapr-key`), OAuth2 bearer, or none.
- `reshapr run -r <release> [--ui]` starts the official local stack (Postgres, control plane, MCP server, optional UI).
- `reshapr import … --apiKey --audit` publishes an OpenAPI as an MCP server and prints the key once.

**sbx**
- `credentials[].apiKey{proxyManaged, inject[]}`: the container holds a placeholder, the proxy swaps in the real value.
- `permissions.network.allow`, `environment`, `setup.install`, `args`, `agentInstructions`.
- `sbx secret set <service>` stores the value on the host.

## 3. Findings (verified)

1. **Host-local services go through the sbx proxy**, so key injection works. `host.docker.internal` is not in the
   default `NO_PROXY`; the proxy rewrites the target to **`localhost:<port>`**. Do not copy the grafana kit's
   `NO_PROXY` override: it bypasses the proxy and the injection.
2. **Use `localhost` everywhere on the sbx side.** The allow rule is `localhost:7777` and `inject.domain` is
   `localhost`. `host.docker.internal` in either place is blocked or not injected. The client config still uses
   `http://host.docker.internal:<port>/mcp/…`.
3. **A user-side binding is required.** sbx injects only into domains the user allows
   (`~/.config/sbx/credentials.yaml`, `reshapr` → `localhost`, empty `discovery`). Without it:
   `credential not sent: no binding authorizes this service`. `scripts/bind.sh` creates it only if absent.
4. **Store the secret before creating the sandbox.** `SBX_CRED_RESHAPR_MODE` is fixed at creation. Set it with
   `sbx secret set reshapr` (global); rotating applies live to running sandboxes.
5. **Agents.** Claude Code (`claude mcp add --transport http --header`): Connected. Codex (`http_headers` in
   `config.toml`) and Copilot CLI (`~/.copilot/mcp-config.json`, jq merge): registered and listed. For all three,
   the MCP round trip (`initialize`, `tools/list`, `tools/call`) works from inside the sandbox. A live Copilot
   prompt also works (credential: `sbx secret set copilot`, with `gh auth token` pasted or via `--command`).
   The first `tools/call` can hit reShapr's 3 s backend timeout, so `verify` retries it.
6. **Negative tests.** No or wrong key gives 401. Direct access from the sandbox to the backend is blocked (403 under
   deny-all) while the same API works through the reShapr server.
7. **Checks done:** `sbx kit validate`, the sbx-kits-contrib TCK (`TestKitTCK`), `make verify` for the three agents.

## 4. Design decisions and limits

- Mixin kit, minimal egress (only the reShapr server port), no download in `setup.install`.
- Registration is guarded per agent binary and idempotent (`|| true` for `claude mcp add`, grep guard for Codex, jq merge for Copilot).
- One exposition per kit instance: the key belongs to a Configuration Plan and the credential service name is fixed.
- Allowing `localhost:7777` also matches any other local service on that port: the port is the trust boundary.
- API-key auth only. OAuth2 would need a host-side token refresher (JWTs expire) and an IdP; deferred.

## 5. Risks

| Risk | Mitigation |
|---|---|
| Key leaks into agent context or config | Placeholder only; configs reference `$RESHAPR_API_KEY`; the real key never enters the sandbox |
| Agent reaches the control plane (:5555) | The kit allows only the reShapr server port |
| The reShapr endpoint on the host is not isolated | reShapr include/exclude operations, `--audit`, per-sandbox keys via key renewal |
| Dev-only defaults (`admin/password`, sample keys) | Local use only; never reuse |

## 6. TODO

- [ ] **Run the e2e suite** (`TestE2EKit`, `scripts/test-kit-e2e.sh` in sbx-kits-contrib). Not run yet. Needs a
  `testdata/tck.yaml` for the mixin, an interactive `sbx --app-name sbx-kits-contrib-tck login`, and a check of the
  Linux `/dev/kvm` requirement on macOS. Do it before proposing the kit upstream (CI skips e2e for fork PRs).
- [ ] Live prompts for Codex and Claude (need their logins). Copilot is done.
- [ ] Isolated sbx daemon mode (`SBX_APP`): login did not persist in tests; retest or drop.
- [ ] Deferred: OAuth2, several expositions, remote reShapr server, a "builder" kit (reShapr CLI + the `reshapr-builder`
  skill, no Docker in the sandbox, low-privilege control-plane credential), Code Mode (reShapr 1.1 roadmap),
  registering reShapr behind sbx's own MCP gateway.
- [ ] Upstream: propose the kit to sbx-kits-contrib; a "Use with Docker Sandboxes" page in the reShapr docs.
