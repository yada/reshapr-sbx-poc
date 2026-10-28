# reshapr-sbx-poc

Proof of concept: two **Docker Sandboxes (sbx) kits** that give a sandboxed coding agent governed access to your APIs through a **[reShapr](https://github.com/reshaprio/reshapr) MCP server**.

- **sbx** isolates the agent (VM, deny-by-default network, credentials kept on the host).
- **reShapr** turns REST/GraphQL/gRPC APIs into MCP tools, with API-key auth, audit and trimmed responses.

| Kit | reShapr runs | Image |
|---|---|---|
| **reshapr-outside-sbx** | on your host, reached through the sbx MCP gateway (the API key stays on the host) | `docker.io/yadayac/reshapr-outside-sbx:0.3.0` |
| **reshapr-inside-sbx** | inside the sandbox, in its own Docker daemon (nothing on the host) | `docker.io/yadayac/reshapr-inside-sbx:0.3.0` |

```
 OUTSIDE                                                 INSIDE
 ┌─ sbx sandbox ─┐        ┌──────── host ────────┐       ┌────────── sbx sandbox ──────────┐
 │ agent         │  sbx   │ reShapr :7777 ─► API │       │ agent ─► reShapr :7777 ─► API   │
 │  mcp-gateway ─┼─ MCP ──┼─► key added by sbx   │       │          (compose, own daemon)  │
 └───────────────┘ gateway└──────────────────────┘       └─────────────────────────────────┘
```

Demo backend: the public [Open-Meteo](https://open-meteo.com) weather API (no account needed).

Both kits are published as multi-arch OCI images with provenance, and signed (keyless Sigstore). Verify with:

```bash
sbx kit verify docker.io/yadayac/reshapr-outside-sbx:0.3.0 \
  --certificate-identity yacine@microcks.io \
  --certificate-oidc-issuer https://github.com/login/oauth
```

## Which one?

| | Outside | Inside | Plain gateway (no kit) |
|---|---|---|---|
| reShapr runs | on the host | in the sandbox | on the host |
| Host steps | `make up`, secret, `sbx mcp add` | none | `make up`, secret, `sbx mcp add` |
| API key | stays on the host | none (no key) | stays on the host |
| Tool name the agent sees | `get_v1_forecast` via `mcp-gateway` | `reshapr` server, `get_v1_forecast` | same as outside |
| Agent knows about reShapr | yes (agent-context) | yes (agent-context) | no |
| Startup | instant | about 1 minute per boot | instant |
| Extra egress to allow | none | registry.reshapr.io, quay.io, cdn01.quay.io, raw.githubusercontent.com, api.open-meteo.com (set in the kit) | none |
| Memory | host | about 1 GB in the sandbox | host |

Use **inside** for an isolated, ready-made environment with a single `sbx create`. Use **outside** to share one reShapr server (and its audit) across sandboxes and keep the key on the host.

## Prerequisites

`sbx` 0.50.0 or later (tested on 0.49.2 and 0.50.0), signed in (`sbx login`), and `curl`. For **outside** only: Docker (Compose v2), and the reShapr CLI (Node 22+): `npm install -g @reshapr/reshapr-cli --allow-scripts=@scarf/scarf` ([docs](https://reshapr.io/docs/tutorials/getting-started)). If `reshapr` is not on your PATH, the scripts run it with `npx @reshapr/reshapr-cli@<release>` (slower on the first run).

Outside mode needs free ports 5555 and 7777 on the host (3333 with `UI=1`).

## Quick start

Pick an agent, then one mode. Run every step in the same terminal, because the agent block sets `BASE`.

**1. Pick your agent** and copy **one** block. Each block stores the agent's own credential and sets `BASE`.

*Claude* (tested live). Paste your Anthropic key when asked; create it in a dedicated Anthropic Console workspace, not at org level:

```bash
sbx secret set anthropic
export BASE=docker.io/docker/sbx-kit-claude:2.1.296
```

*Copilot* (tested live). This reads your `gh` login (run `gh auth login` first). See [Copilot needs two secrets](#copilot-needs-two-secrets):

```bash
sbx secret set github  --command "$(which gh) auth token"
sbx secret set copilot --command "$(which gh) auth token"
export BASE=docker.io/docker/sbx-kit-copilot:1.0.86
```

*Codex* (tested live; ask "…using the reshapr tool", because Codex otherwise prefers its built-in web search, even with the kit's agent-context note). Paste your OpenAI key when asked:

```bash
sbx secret set openai
export BASE=docker.io/docker/sbx-kit-codex:0.162.1
```

**2a. Inside** (nothing to start on the host):

```bash
sbx create "$BASE" --name reshapr-in --kit docker.io/yadayac/reshapr-inside-sbx:0.3.0
sbx run reshapr-in
```

reShapr starts in the background about a minute after boot. Wait until `sbx exec reshapr-in tail -3 /tmp/reshapr-start.log` ends with an `Endpoints` line (the import is done), then start the agent. The agent talks to it on `localhost:7777`.

**2b. Outside.** Clone this repo, then start reShapr on the host and register it with the sbx MCP gateway. Set the secret **first**; otherwise `sbx mcp add` fails with a misleading OAuth discovery error:

```bash
make up
sbx secret set mcp:reshapr:api-key < .state/api-key
sbx mcp add reshapr --url http://localhost:7777/mcp/reshapr/open-meteo-weather-forecast-api-1-0-default \
  --header 'x-reshapr-key: ${api-key}' --skip-ssrf-check
sbx mcp ls                                   # expect: reshapr  ready
sbx create "$BASE" --name reshapr-out --static-mcp reshapr \
  --kit docker.io/yadayac/reshapr-outside-sbx:0.3.0
sbx run reshapr-out
```

**3. Ask:** *"give the forecast in SFO"*. The first call may time out (3 s backend timeout); the agent retries. In outside mode the agent sees one `mcp-gateway` with an unprefixed `get_v1_forecast` (plus `code-mode` and `mcp-exec`), not a server called `reshapr`. The kit's agent-context note tells it so.

**Clean up:**

```bash
sbx rm -f reshapr-in reshapr-out
sbx mcp rm --force reshapr
sbx secret rm --force mcp:reshapr:api-key
sbx secret rm --force mcp:reshapr:api-key:endpoint
make down
```

Your agent's own secret (`anthropic`, `github` and `copilot`, or `openai`) stays stored; remove it with `sbx secret rm --force <name>`.

## Run the checks

```bash
make up                                  # outside only: reShapr on the host + API key
MODE=outside AGENT=claude make verify    # MODE=outside|inside, AGENT=claude|codex|copilot
make down                                # remove sandbox, gateway registration, secrets, stack, state
make validate                            # sbx kit inspect on both kits
```

`make verify` needs **no agent or model login**; it uses `sbx exec` and `curl`. Outside proves: the agent registers `mcp-gateway`, the kit's agent-context is installed, and the API key is not in the sandbox. Inside proves: reShapr starts and imports the API, the agent has `reshapr` registered, and an MCP `initialize` → `tools/list` → `tools/call get_v1_forecast` round trip works.

Results: all 6 combinations (3 agents × 2 modes) pass on sbx 0.49.2 and 0.50.0; the kit TCK passes 19/19 on both published images. Live prompts were run for Claude, Codex and Copilot on both modes.

### Try it without an agent login

```bash
sbx exec reshapr-in bash -s -- http://localhost:7777/mcp/reshapr/open-meteo-weather-forecast-api-1-0-default < scripts/mcp-smoke.sh
sbx exec reshapr-in copilot mcp list        # or claude / codex
```

### Try it with a live prompt

The agent needs its own credential, stored on the host **before** the sandbox is created:

| Agent | `sbx secret set …` | What to paste |
|---|---|---|
| claude | `anthropic` | Console API key or Claude subscription login. Create the key in a dedicated workspace with its own spend limit |
| codex | `openai` | OpenAI API key or ChatGPT login |
| copilot | **both** `github` and `copilot` | `gh auth token` output (or a fine-grained PAT with *Copilot Requests*) |

> **Warning:** `gh auth token` returns your `gh` login token, which has broad scopes. The sbx proxy injects it only on the Copilot domains and it never enters the sandbox, but a fine-grained PAT limited to *Copilot Requests* is the least-privilege choice.

#### Copilot needs two secrets

| Service | Injected on | Used for |
|---|---|---|
| `github` | `api.github.com`, `github.com` | Copilot validates its token here at startup |
| `copilot` | `*.githubcopilot.com`, `copilot.github.com` | Model calls |

Symptoms (observed): without `github`, Copilot starts with `Authentication token found but could not be validated. GitHub returned: Bad credentials`; with `github` but without `copilot`, the model catalog returns 401.

A third cause (observed on sbx 0.48.0, not reproduced on 0.50.0): if you removed the `github` secret while a sandbox of that name existed, sbx logs `secrets: credential revoked` and the revoked state sticks to the sandbox **name**. Use another name (`SANDBOX=<name> make verify`, or `sbx create --name <name>`). the `github` secret while a sandbox of that name existed, sbx logs `secrets: credential revoked` and the revoked state sticks to the sandbox **name**. Use another name (`SANDBOX=<name> make verify`, or `sbx create --name <name>`).

## Use your own API

**Inside:** pass kit args (see `sbx create --help`). Add the hosts of your OpenAPI document and backend to the sandbox allow list (`sbx policy allow network <host>`):

```bash
sbx create "$BASE" --kit docker.io/yadayac/reshapr-inside-sbx:0.3.0 \
  --kit-arg openapi=<openapi-url> --kit-arg backend=<api-base-url> \
  --kit-arg exposition=<org>/<exposition-name>
```

Args: `release` (default `1.0.0`), `openapi`, `backend`, `exposition`. The exposition path comes from the API's title and version, so the first run tells you the right value: `sbx exec <sandbox> reshapr expo list` (put `~/.npm-g/bin` on PATH), then recreate with `--kit-arg exposition=…`. Tested with the Petstore API (`openapi=https://petstore3.swagger.io/api/v3/openapi.json`, `backend=https://petstore3.swagger.io/api/v3`, exposition `reshapr/swagger-petstore-openapi-3-0-1-0-28-default`, plus `sbx policy allow network petstore3.swagger.io`): Claude called `get_pet_findbystatus` through the `reshapr` server.

**Outside:** import the API into reShapr on the host (`reshapr import -u <openapi-url> --backendEndpoint <api-base-url> --apiKey --audit`, which prints the key once; `reshapr expo list` for the path), then use that key and URL in the `sbx secret set` and `sbx mcp add` steps. The CLI here keeps its session in `.state/home`, so run it with `HOME=$PWD/.state/home`.

## Migrating from 0.2.0

`docker.io/yadayac/reshapr-kit:0.2.0` (tag `v0.2.0`) stays published. 0.3.0 is a breaking change:

- The old kit's per-agent hooks, `reshapr` credential, network rule and `scripts/bind.sh` are gone. Registration now goes through the sbx MCP gateway (outside) or runs in the sandbox (inside).
- The kit moved to `reshapr-outside-sbx` (agent-context only). Outside mode now needs `sbx secret set mcp:reshapr:api-key`, `sbx mcp add … --skip-ssrf-check` and `--static-mcp reshapr`.
- The tool is `get_v1_forecast` behind `mcp-gateway`, not `reshapr-get_v1_forecast`.

## Publish and sign your own copy

A v3 kit is an OCI image. Build with buildx and a **`docker-container` builder** (Docker Desktop's default builder pushes a plain image that sbx rejects with "no artifactType"):

```bash
docker buildx create --name kitpub --driver docker-container
K=reshapr-outside-sbx                       # or reshapr-inside-sbx
docker buildx build ./sbx-kits/$K -f ./sbx-kits/$K/$K.yaml \
  --platform linux/amd64,linux/arm64 --provenance=true --sbom=false \
  -t docker.io/<namespace>/$K:0.3.0 --builder kitpub --push
sbx kit sign docker.io/<namespace>/$K:0.3.0      # keyless; opens a browser login
```

The kit's name comes from the repository name.

## MCP server from a host client (MCPJam, Inspector, …)

In outside mode the same server can be queried from the host. Auth is an API key in a custom header, not a bearer token:

- URL: `http://localhost:7777/mcp/<org>/<exposition-name>`
- Header: `x-reshapr-key: <key>` (from `.state/api-key` while `make up` is running)
- In [MCPJam](https://github.com/MCPJam/inspector), set authentication to none and add the header under "Edit server details".

## What's in the repo

| Path | Purpose |
|---|---|
| `sbx-kits/reshapr-outside-sbx/reshapr-outside-sbx.yaml` | Outside kit (v3 mixin): agent-context only |
| `sbx-kits/reshapr-inside-sbx/reshapr-inside-sbx.yaml` | Inside kit (v3 mixin): args, network allow list, `long-running`, install and startup hooks, agent-context |
| `scripts/up.sh` | `reshapr run -r <release>` on the host (outside), CLI login, API import, key saved to `.state/api-key` |
| `scripts/verify.sh`, `mcp-smoke.sh` | Sandbox creation and checks (`MODE`, `AGENT`) |
| `scripts/down.sh` | Cleanup |

The host stack is reShapr's own (`reshapr run`), pinned with `RESHAPR_RELEASE` (default `1.0.0`). The CLI runs with `HOME=.state/home`, so your real `~/.reshapr` is untouched.

## How it works, and the gotchas

- **Outside:** the host stack can go stale (expired CLI token, lost exposition): the gateway then lists only `code-mode` and `mcp-exec` and agents fall back to web search. `make verify` checks the host exposition first; if it fails, run `make down && make up`.
- **Outside:** the sbx MCP gateway is host-side, so it reaches `localhost:7777` and adds the key; the sandbox never sees it. The agent sees `mcp-gateway`, which is why the agent-context note names the tools.
- **Inside:** the gateway can't reach a sandbox's `localhost`, so the kit registers the server in each agent's own config (Claude `claude mcp add`, Codex `~/.codex/config.toml`, Copilot `~/.copilot/mcp-config.json`), with no key.
- **Inside startup timing:** an agent session opened before the import finishes has no reShapr tools and may fall back to web search. Wait for the import to finish: `sbx exec <sandbox> tail -3 /tmp/reshapr-start.log` should end with the `Endpoints` line (the agent can list `reshapr` as connected before that). Then start a new session if needed. Tested with a Claude subscription `/login` (no API-key secret): works.
- **Inside needs `long-running@1`.** Without it the sandbox auto-stops with no client attached, and after a reboot the server can start before the control plane and never recover. The startup hook restarts `reshapr-gateway-01` when `:7777` is unhealthy.
- **Inside startup:** each boot runs `reshapr run` and re-imports the API when the exposition is missing (Postgres is not persisted across stop/start). It takes about a minute and about 1 GB RAM. `registry.reshapr.io` redirects blobs to `cdn01.quay.io`, so that host must be allowed; it may change.
- The kits are **schema v3**. A v3 mixin must be composed with a v3 *workload* (the published `docker.io/docker/sbx-kit-<agent>:<version>`, pinned in `scripts/common.sh`); the built-in names fail with "no workload kit in the set".
- v3 source kits are built, not just parsed. The scripts set `SBX_KIT_BUILDER=sandbox`; `sbx kit validate` doesn't accept v3 source kits, so `make validate` runs `sbx kit inspect`.
- `sbx secret set` fails non-interactively if the secret exists (use `sbx secret rm --force` first); `sbx mcp rm` needs `--force`.
- The first forecast call can hit reShapr's 3 s backend timeout; `make verify` retries.
- Dev-only credentials (`admin/password`, fixed keys in reShapr's local compose stack). Never reuse them.

## Limits and next steps

Design notes, findings and the TODO list: [docs/PLAN.md](docs/PLAN.md).

- One exposition per kit; API-key auth only (outside) or no auth (inside, sandbox-local); no OAuth2.
- Codex prefers web search unless the prompt says to use the reshapr tool.
- The e2e suite (`scripts/test-kit-e2e.sh`) can't run for v3 source kits yet: [docker/sbx-kits-contrib#446](https://github.com/docker/sbx-kits-contrib/issues/446).
- Next: remote reShapr server, several expositions, OAuth2, persistence for the inside kit, a "builder" kit.

## License

[Apache License 2.0](LICENSE).
