# reshapr-sbx-poc

Proof of concept: a **Docker Sandboxes (sbx) kit** that gives a sandboxed coding agent governed access to your APIs through a **[reShapr](https://github.com/reshaprio/reshapr) MCP server**.

- **sbx** isolates the agent (VM, deny-by-default network, credentials kept on the host).
- **reShapr** turns REST/GraphQL/gRPC APIs into MCP tools, with API-key auth, audit and trimmed responses.
- **The kit** wires the two: it registers the exposition with the agent and lets the sbx proxy inject the reShapr API key, so the key never enters the sandbox.

```
 ┌──────────── sbx sandbox ─────────────┐        ┌────────────── host ───────────────┐
 │ agent (Claude, Codex, Copilot)       │        │ reShapr server :7777 ──► backend  │
 │  MCP: x-reshapr-key: proxy-managed ──┼─ sbx ──┼─► (checks key, audits, trims)     │
 │  direct backend access: BLOCKED      │ proxy  │ reShapr control plane :5555 + PG  │
 └──────────────────────────────────────┘ injects└───────────────────────────────────┘
                                          real key
```

Demo backend: the public [Open-Meteo](https://open-meteo.com) weather API (no account needed).

## Prerequisites

Docker (Compose v2), `sbx` 0.48.0 or later, signed in (`sbx login`), `curl`, and the reShapr CLI (Node 22+):
`npm install -g @reshapr/reshapr-cli --allow-scripts=@scarf/scarf` ([docs](https://reshapr.io/docs/tutorials/getting-started)).
The global install is optional: if `reshapr` is not on your PATH, the scripts run the same CLI on demand with `npx @reshapr/reshapr-cli@<release>` (pinned to `RESHAPR_RELEASE`). That path needs Node 22+ and is slower on the first run because the CLI is downloaded.

Free ports 5555 and 7777 (3333 with `UI=1`).

## Quick start

Pick an agent, then follow path A (the kit) or path B (the sbx MCP gateway). Run every step in the same terminal, because step 2 sets `BASE` for the later commands.

**1. Start reShapr** (clone this repo first). `make up` starts reShapr with Open-Meteo and an API key, and `bind.sh` lets the sbx proxy use the `reshapr` secret:

```bash
make up
./scripts/bind.sh
sbx secret set reshapr < .state/api-key
```

**2. Pick your agent** and copy **one** block. Each block stores the agent's own credential and sets `BASE`.

*Claude* (tested live on both paths). Paste your Anthropic key when asked; create it in a dedicated Anthropic Console workspace, not at org level:

```bash
sbx secret set anthropic
export BASE=docker.io/docker/sbx-kit-claude:2.1.296
```

*Copilot* (tested live on both paths). This reads your `gh` login (run `gh auth login` first). See [Copilot needs two secrets](#copilot-needs-two-secrets) for the token-scope warning:

```bash
sbx secret set github  --command "$(which gh) auth token"
sbx secret set copilot --command "$(which gh) auth token"
export BASE=docker.io/docker/sbx-kit-copilot:1.0.86
```

*Codex* (tested live on the kit and the gateway; ask "…using the reshapr tool", because Codex otherwise prefers its built-in web search). Paste your OpenAI key when asked:

```bash
sbx secret set openai
export BASE=docker.io/docker/sbx-kit-codex:0.162.1
```

**3a. Path A, the kit.** Expect the install commands to pass:

```bash
sbx create "$BASE" --name reshapr-sbx --kit docker.io/yadayac/reshapr-kit:0.2.0
sbx run reshapr-sbx
```

**3b. Path B, the gateway** (no kit). Set the secret first. Expect `reshapr  ready` in `sbx mcp ls`:

```bash
sbx secret set mcp:reshapr:api-key < .state/api-key
sbx mcp add reshapr --url http://localhost:7777/mcp/reshapr/open-meteo-weather-forecast-api-1-0-default \
  --header 'x-reshapr-key: ${api-key}' --skip-ssrf-check
sbx mcp ls
sbx create "$BASE" --name reshapr-gw --static-mcp reshapr
sbx run reshapr-gw
```

**4. Ask:** *"give the forecast in SFO"*. Path A calls `reshapr-get_v1_forecast` through the `reshapr` server; path B calls `get_v1_forecast` through `mcp-gateway`. The first call may time out; the agent retries.

**Which path?** Path A is one `--kit` flag and tells the agent about reShapr. Path B keeps the key out of the sandbox entirely, but the agent can't address `reshapr` by name. Details are [below](#alternative-the-sbx-mcp-gateway-no-kit).

**Clean up:**

```bash
sbx rm -f reshapr-sbx reshapr-gw
sbx mcp rm --force reshapr
sbx secret rm --force mcp:reshapr:api-key
sbx secret rm --force mcp:reshapr:api-key:endpoint
make down
```

Your agent's own secret (`anthropic`, `github` and `copilot`, or `openai`) stays stored; remove it with `sbx secret rm --force <name>` if you don't want to keep it.

## Run it

```bash
make up       # start reShapr, import Open-Meteo as an MCP server (API key + audit on)
              # make up UI=1 also starts the web UI on http://localhost:3333 (admin / password)
make verify   # create the sandbox with the kit and run the checks
make down     # remove everything (sandbox, secret, containers, volumes, state)
```

`make verify` proves four things:

1. The agent has `reshapr` registered (for Claude Code, `claude mcp list` shows **Connected**).
2. From inside the sandbox, `initialize` → `tools/list` → `tools/call get_v1_forecast` succeed, and `$RESHAPR_API_KEY` is only the placeholder `proxy-managed`.
3. The reShapr server returns **401** without a key.
4. The backend is not reachable directly from the sandbox (403 under a deny-all policy).

Agents (`AGENT=claude|codex|copilot make verify`, default `claude`):

| Agent | Registration | Verified |
|---|---|---|
| Claude Code | `claude mcp add` | Connected (live) + MCP round trip |
| Codex | `~/.codex/config.toml` (`http_headers`) | `codex mcp list` enabled + MCP round trip |
| Copilot CLI | `~/.copilot/mcp-config.json` (jq merge) | `copilot mcp list` + MCP round trip |

For Codex a live prompt was tested with an OpenAI API key: it called `reshapr.get_v1_forecast` when the prompt said "using the reshapr tool"; without that hint it used web search. For Copilot a live prompt was tested: it found and called `get_v1_forecast`.

`make verify` needs **no agent or model login**: it only uses `sbx exec` and `curl` inside the sandbox. Only a live prompt needs the agent's own credential.

### Try it without an agent login

```bash
sbx exec reshapr-sbx bash -s < scripts/mcp-smoke.sh   # MCP round trip, key injected by the proxy
sbx exec -it reshapr-sbx bash                         # shell; try curl against http://host.docker.internal:$RESHAPR_PORT/mcp/$RESHAPR_EXPOSITION
sbx exec reshapr-sbx copilot mcp list                 # registration (or claude / codex)
```

### Try it with a live prompt

The agent needs its own credential. Store it on the host **before** the sandbox is created (the mode is fixed at creation):

| Agent | `sbx secret set …` | What to paste |
|---|---|---|
| claude | `anthropic` | Console API key or Claude subscription login (optional: `/login` also works inside the sandbox). Create the key in a dedicated Anthropic Console workspace with its own spend limit, not at org level |
| codex | `openai` | OpenAI API key or ChatGPT login |
| copilot | **both** `github` and `copilot` | Your `gh auth token` output for each (pasted or via Option B below, both tested), or a fine-grained PAT with the *Copilot Requests* permission. See "Copilot needs two secrets" below |

```bash
# Option A: paste a token when prompted
sbx secret set <service>        # from the table above, e.g. anthropic or openai

# Option B (Copilot): sbx reads the token from your gh login on the host
sbx secret set github  --command "$(which gh) auth token"
sbx secret set copilot --command "$(which gh) auth token"

make down && make up            # recreate, so the credential applies
AGENT=<agent> make verify       # creates the sandbox, e.g. AGENT=copilot
sbx run reshapr-sbx             # start the agent
```

> **Warning:** `gh auth token` returns your `gh` login token, which has broad scopes (for example `repo`, `workflow`, `read:org`). The sbx proxy injects it only on the Copilot domains and it never enters the sandbox, but a fine-grained PAT limited to *Copilot Requests* is the least-privilege choice.

Then ask *"What's the weather forecast for Paris? Use the reshapr tools."* The first call to the backend may time out (3 s backend timeout); the agent usually retries with a smaller request.

#### Copilot needs two secrets

The Copilot kit declares two credential services, and both must be set before the sandbox is created:

| Service | Injected on | Used for |
|---|---|---|
| `github` | `api.github.com`, `github.com` | Copilot validates its token here at startup |
| `copilot` | `*.githubcopilot.com`, `copilot.github.com` | Model calls |

Both can hold the same value (`gh auth token`, or a fine-grained PAT with *Copilot Requests*). Steps:

```bash
sbx secret set github  --command "$(which gh) auth token"
sbx secret set copilot --command "$(which gh) auth token"
sbx secret ls                   # check both are listed
make down && make up && AGENT=copilot make verify
sbx run reshapr-sbx
```

Symptoms (observed): without `github`, Copilot starts with `Authentication token found but could not be validated. GitHub returned: Bad credentials`; with `github` but without `copilot`, the model catalog returns 401.

A third cause (observed on sbx 0.48.0): if you removed the `github` secret while a sandbox of that name existed, sbx logs `secrets: credential revoked` for it, and the revoked state sticks to the sandbox **name**. Re-creating a sandbox with the same name keeps failing with "Bad credentials" even with the secret set again; a different name works. Use another name with `SANDBOX=<name> make verify` or `sbx create --name <name>`.

### Use your own API

`make up` only imports the demo API. To expose another one, import it into reShapr and point the kit at it:

```bash
reshapr import -u <openapi-url> --backendEndpoint <api-base-url> --apiKey --audit   # prints the API key once
reshapr expo list                                                                  # find <org>/<exposition-name>
sbx secret rm reshapr --force; sbx secret set reshapr                              # paste the key
sbx create docker.io/docker/sbx-kit-claude:2.1.296 --kit ./reshapr --kit-arg exposition=<org>/<exposition-name>   # see `sbx create --help`
```

(The `reshapr` CLI here is the one from `make up`: it keeps its session in `.state/home`, so run it with `HOME=$PWD/.state/home`.)

### Use the published kit

The kit is published on Docker Hub as `docker.io/yadayac/reshapr-kit:0.2.0`, so you can use it without cloning the repo. You still need a reShapr server running on the host and the `reshapr` secret set before `sbx create` (`make up` does both for the demo):

| Agent | Workload (`BASE`) | Extra secrets |
|---|---|---|
| Claude | `docker.io/docker/sbx-kit-claude:2.1.296` | none |
| Codex | `docker.io/docker/sbx-kit-codex:0.162.1` | none |
| Copilot | `docker.io/docker/sbx-kit-copilot:1.0.86` | `github` and `copilot` (see [Copilot needs two secrets](#copilot-needs-two-secrets)) |

```bash
BASE=docker.io/docker/sbx-kit-claude:2.1.296   # pick a workload from the table
sbx create "$BASE" --name reshapr-sbx --kit docker.io/yadayac/reshapr-kit:0.2.0
```

Versions: release `v0.2.0` is the current spec v3 kit; `v0.1.0-v2` is the legacy spec v2 kit.

### Alternative: the sbx MCP gateway (no kit)

sbx also has a [host-managed MCP gateway](https://docs.docker.com/ai/sandboxes/mcp-gateway/). You register the reShapr exposition once on the host, and every sandbox gets it through one gateway endpoint. Set the secret **first**; otherwise the add fails with a misleading OAuth discovery error:

```bash
sbx secret set mcp:reshapr:api-key < .state/api-key
sbx mcp add reshapr --url http://localhost:7777/mcp/reshapr/open-meteo-weather-forecast-api-1-0-default \
  --header 'x-reshapr-key: ${api-key}' --skip-ssrf-check
sbx create "$BASE" --name reshapr-gw --static-mcp reshapr   # no --kit
```

Tested on sbx 0.48.0: Claude, Codex and Copilot each register `mcp-gateway` by itself, and a `get_v1_forecast` call returned real data. All three were also tested with a live prompt (macOS; Claude and Codex with an API key, Copilot with `gh auth token`). Codex needs "using the reshapr tool" in the prompt, otherwise it uses web search. The key stays on the host (no placeholder, no `RESHAPR_API_KEY` in the sandbox) and no allow rule is needed.

Differences from the kit:

- The tool is named `get_v1_forecast` (not `reshapr-get_v1_forecast`), and the gateway adds `code-mode` and `mcp-exec`.
- It is host state, not an artifact: nothing to distribute, and no agent-context text.
- The agent sees one `mcp-gateway`, not a server called `reshapr`, so "use the reshapr tool" fails. Name the tool, or add a line to your project instructions.
- After rotating the secret, restart the sandbox.
- Copilot is not on the docs' list of supported agents, but it works: a live prompt called `get_v1_forecast` through `mcp-gateway`, including an hourly follow-up.

Use the kit for a single `--kit` command and the agent-context text; use the gateway if you prefer to keep the key out of the sandbox entirely.

### Publish the kit (optional)

`docker.io/yadayac/reshapr-kit:0.2.0` is already published; this section is for publishing your own copy. A v3 kit is an OCI image, so others can use it without cloning the repo. `sbx kit push` is v1/v2 only on sbx 0.48.0; publish with buildx and a **`docker-container` builder** (Docker Desktop's default builder pushes a plain image that sbx rejects with "no artifactType"):

```bash
REF=docker.io/<your-namespace>/reshapr-kit:0.2.0
docker buildx create --name kitpub --driver docker-container
docker buildx build ./reshapr -f ./reshapr/reshapr.yaml -t "$REF" --builder kitpub --push

# consume it, no local build:
sbx create docker.io/docker/sbx-kit-claude:2.1.296 --kit "$REF"
```

(The kit's name comes from the repository name, so `reshapr-kit` above.)

### Use the MCP server from a host client (MCPJam, Inspector, …)

The same server can be queried outside sbx. Auth is an API key in a custom header, not a bearer token:

- URL: `http://localhost:7777/mcp/<org>/<exposition-name>` (the demo one is `/mcp/reshapr/open-meteo-weather-forecast-api-1-0-default`)
- Header: `x-reshapr-key: <key>`, with the key from `.state/api-key` (while `make up` is running)
- In [MCPJam](https://github.com/MCPJam/inspector), the Bearer Token and OAuth options don't apply. Set authentication to none and add the header under "Edit server details".

### Isolated sbx daemon (experimental)

`sbx --app-name reshapr-sbx login`, `sbx --app-name reshapr-sbx policy init deny-all`, then `SBX_APP=reshapr-sbx make verify`. It needs an interactive login and was not reliable in my tests; the default daemon is the tested path.

## What's in the repo

| Path | Purpose |
|---|---|
| `reshapr/reshapr.yaml` | The kit (v3 mixin): args, credential, network allow, MCP registration, agent instructions |
| `scripts/up.sh` | `reshapr run -r <release> [--ui]` (reShapr's official all-in-one stack), CLI login, API import, saves the key to `.state/api-key` |
| `scripts/bind.sh` | Creates the user-side sbx credential binding (only if absent) |
| `scripts/verify.sh`, `mcp-smoke.sh` | Sandbox creation and checks |
| `scripts/down.sh` | Cleanup |

The stack is reShapr's own (`reshapr run`), pinned with `RESHAPR_RELEASE` (default `1.0.0`). The CLI runs with `HOME=.state/home`, so your real `~/.reshapr` session and data are untouched; `make down` runs `reshapr stop` and deletes `.state`.

Kit args: `port` (default `7777`) and `exposition` (`<org>/<exposition-name>`, see `reshapr expo list`).

## How it works, and the gotchas

- Inside the sandbox, `localhost` is the sandbox itself, so clients (each agent's MCP config, and `scripts/mcp-smoke.sh`) use `host.docker.internal:7777` to reach the host. The sbx proxy also handles host traffic and rewrites `host.docker.internal` to **`localhost`**. So the allow rule (`localhost:7777`) and the credential `inject.domain` (`localhost`) must both use `localhost`.
- The kit is **schema v3** (`reshapr/reshapr.yaml`; the v2 version is tagged `v0.1.0-v2`). A v3 mixin must be composed with a v3 *workload*: the built-in names `claude` and `codex` failed with "no workload kit in the set", so `make verify` uses the published workloads (`docker.io/docker/sbx-kit-<agent>:<version>`, pinned in `scripts/common.sh`).
- v3 source kits are built, not just parsed. On Docker Desktop's classic image store the host build fails ("OCI exporter is not supported for the docker driver"), so the scripts set `SBX_KIT_BUILDER=sandbox` to build in sbx's builder sandbox. `sbx kit validate` doesn't accept v3 source kits; `make validate` runs `sbx kit inspect` instead.
- A v3 mixin can't set an environment variable without an image recipe, so the v2 `RESHAPR_MCP_URL` is gone. The args are exported as `RESHAPR_PORT` and `RESHAPR_EXPOSITION` instead.
- sbx injects a credential only into domains the **user** allows. `scripts/bind.sh` creates `~/.config/sbx/credentials.yaml` (`reshapr` → `localhost`) if that file doesn't exist; `make down` removes it if the POC created it. Otherwise you get `credential not sent: no binding authorizes this service`.
- Store the key with `sbx secret set reshapr` (global) **before** creating the sandbox: `SBX_CRED_RESHAPR_MODE` is fixed at creation. Rotate with `sbx secret rm reshapr --force` then `set`.
- Do not copy the grafana kit's `NO_PROXY` override: it bypasses the proxy and the injection.
- `claude mcp add` is not idempotent, hence `|| true` in the install step.
- The first forecast call can hit reShapr's 3 s backend timeout (`Backend timed out after 3000ms`); `make verify` retries it up to 3 times.
- Live prompts need the agent's own credential, set before creating the sandbox (see the table under "Try it with a live prompt"). Copilot needs both `github` and `copilot`; "Bad credentials" means `github` is missing. Set it, then recreate the sandbox.
- Dev-only credentials (`admin/password`, fixed keys in reShapr's local compose stack). Never reuse them.

## Limits and next steps

Design notes, findings and the TODO list: [docs/PLAN.md](docs/PLAN.md).

- One exposition per kit (the credential service is fixed to `reshapr`); local reShapr server only; API-key auth only (no OAuth2).
- Live prompts verified for Claude, Copilot and Codex. Codex prefers its built-in web search for questions like "forecast" unless the prompt says to use the reshapr tool, even with the kit's agent-context note.
- The v3 kit builds with `SBX_KIT_BUILDER=sandbox sbx kit inspect ./reshapr` (`make validate`) and passes `make verify` for claude, codex and copilot. The v2 version passed `sbx kit validate`, the sbx-kits-contrib TCK (`TestKitTCK`) and the e2e suite (`scripts/test-kit-e2e.sh <path-to-kit-dir>`) on sbx 0.47.0; those two have **not** been re-run on v3 (the TCK lives in a private repo for v3).
- Next: remote reShapr server, several expositions, OAuth2, a "builder" kit (reShapr CLI + the `reshapr-builder` skill).

## License

[Apache License 2.0](LICENSE).
