# Design notes: reShapr ⇄ Docker Sandboxes (sbx)

Why this POC exists, what was verified, and what is left. Tested with sbx 0.48.0 (v3 kit; the v2 kit was tested with 0.47.0) and reShapr 1.0.0.

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
- Kit capabilities used: `network-policy@1`, `credential@1`, `lifecycle@1` (install hooks) and `agent-context@1`, plus `args` with `env:`.
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
7. **Checks done:** `make verify` for the three agents on the v3 kit (sbx 0.48.0). On the v2 kit: `sbx kit validate`, the sbx-kits-contrib TCK (`TestKitTCK`) and the e2e suite.
8. **v3 migration** (branch `v3`, v2 tagged `v0.1.0-v2`). Answers to the open questions:
   - `localhost:7777` (with the port) is accepted in the allow rule; hooks see `${{ kit.args.* }}`; the credential works as `optional: true`.
   - No image recipe is needed: `agent-context` uses inline `content`, and args are exported with `env:` (`RESHAPR_PORT`, `RESHAPR_EXPOSITION`). The v2 `RESHAPR_MCP_URL` variable is gone.
   - Hook environments are deny-by-default: each hook declares `env: [RESHAPR_API_KEY]`. The credential spans `[install, runtime]`, so the allow rule is in both phases.
   - `sbx kit validate` rejects v3 source kits, and the host build fails on Docker Desktop's classic image store. `SBX_KIT_BUILDER=sandbox sbx kit inspect ./reshapr` works.
   - A v3 mixin needs a v3 *workload*. The built-in `claude` and `codex` names failed with "no workload kit in the set" (cause not confirmed). The published `docker.io/docker/sbx-kit-{claude,codex,copilot}:<version>` workloads compose fine and are pinned in `scripts/common.sh`.
   - Building the contrib `claude` workload from source in the builder hung on `claude.ai/install.sh`; not needed, since the published image works.
   - Related upstream issues (all closed): `docker/sbx-releases#671`, `#682` (fixed in 0.48.0), `#677` (Windows, fixed on `main` for 0.49.0).
9. **Publishing a v3 kit** (tested with a throwaway `docker.io/yadayac/reshapr-kit:0.2.0-test`):
   - `sbx kit push` is v1/v2 only on 0.48.0 (it requires `spec.yaml`).
   - `docker buildx build ./reshapr -f ./reshapr/reshapr.yaml -t <ref> --push` with Docker Desktop's default `docker` driver pushes a plain image; `sbx kit inspect` rejects it ("no artifactType").
   - The same command with a `docker-container` builder (`--builder kitpub`) pushes a valid kit artifact. `sbx create <workload> --kit <ref>` then pulls it, runs the hooks, and Claude shows the reshapr server `Connected`.
   - The kit directory is named `reshapr`, so a local build shows the kit as `reshapr`. With the older `kit/` name it showed as `kit`.

## 4. Design decisions and limits

- Mixin kit, minimal egress (only the reShapr server port); the install hooks only write agent config, nothing is downloaded.
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

- [x] **e2e suite on the v2 kit, sbx 0.47.0** (`TestE2EKit`, `scripts/test-kit-e2e.sh <kit-dir>` in sbx-kits-contrib): passed on macOS (arm64) with the
  kit's default args (no `testdata/tck.yaml` needed, no `/dev/kvm` needed). Subtests `env`, `tmpfs` and `agentContext` pass.
  It needs a one-time `sbx --app-name sbx-kits-contrib-tck login`, which can be rate-limited by Docker's auth service.
  The log notes that no binding authorizes `reshapr`, which is expected: the user-side binding is created by `scripts/bind.sh`.
- [ ] Live prompts for Codex and Claude (need their logins). Copilot is done.
- [ ] Re-run the e2e suite (and the TCK, if reachable) against the v3 kit; both passed on the v2 kit only.
- [ ] Isolated sbx daemon mode (`SBX_APP`): login did not persist in tests; retest or drop.
- [ ] Deferred: OAuth2, several expositions, remote reShapr server, a "builder" kit (reShapr CLI + the `reshapr-builder`
  skill, no Docker in the sandbox, low-privilege control-plane credential), Code Mode (reShapr 1.1 roadmap),
  registering reShapr behind sbx's own MCP gateway.
- [ ] Deferred, watch [docker/sandbox-kit-spec#118](https://github.com/docker/sandbox-kit-spec/pull/118) (open): the `mcp-server@1`
  capability declares an MCP server that runs **inside** a sandbox and lets sbx serve it to other sandboxes' MCP gateways.
  It doesn't help this POC (reShapr runs on the host and the kit only registers it). It could help a "reShapr in a sandbox"
  kit, which could drop the per-agent registration hooks. Revisit once it merges and ships in an sbx release.
- [ ] Upstream: propose the kit to sbx-kits-contrib; a "Use with Docker Sandboxes" page in the reShapr docs.
