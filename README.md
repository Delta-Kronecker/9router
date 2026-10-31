# 9router on GitHub Actions with Cloudflare Tunnel

Run the 9router AI gateway on a GitHub Actions runner and expose it on a stable HTTPS
domain through a Cloudflare named tunnel. No VPS, no open ports, no DNS work beyond one
record that the tunnel creates for you.

The repository is a thin wrapper around three things:

1. a workflow that installs 9router and cloudflared,
2. a Python seeder that writes every provider API key into 9router's SQLite database,
3. a bash supervisor that starts the server, gates on a real health check, starts the
   tunnel, and keeps the job alive.

---

## How it works

```
GitHub Actions runner (ubuntu-latest)
|
+-- npm install -g 9router
+-- download cloudflared -> /usr/local/bin/cloudflared
|
+-- scripts/setup-providers.py
|     reads provider keys from secrets -> writes ~/.9router/db/data.sqlite
|
+-- scripts/start-tunnel.sh
|     1. fills unset variables from api_keys.env (if present)
|     2. runs the seeder
|     3. starts 9router: 9router -n -l --skip-update -p $PORT -H 0.0.0.0
|     4. health gate: curl -fsS http://127.0.0.1:$PORT/v1/models (up to ~3 min)
|     5. starts cloudflared with the tunnel token (or a quick tunnel)
|     6. prints the public URL and keeps a watchdog loop running
|
+-- Cloudflare edge -> <tunnel-id>.cfargotunnel.com -> http://localhost:20128
                                    ^
                      router.<your-domain> (CNAME, created by the tunnel route)
```

Each run keeps the service up until the workflow is cancelled or the configured
duration is reached. GitHub's hard limit for a job is 6 hours.

---

## Repository layout

```text
.
├── .github/
│   └── workflows/
│       └── run-9router.yml      # installs dependencies, runs the supervisor under a timeout
├── scripts/
│   ├── setup-providers.py       # parses provider keys, seeds SQLite, writes the master key
│   └── start-tunnel.sh          # env handling, service start, health gate, tunnel, watchdog
├── api_keys.env.example         # template for local runs (copy to api_keys.env)
├── .gitignore                   # ignores api_keys.env, .env, providers.conf
└── README.md
```

Nothing in the repository contains credentials. Every key is supplied at runtime
through the runner environment.

---

## Prerequisites

- A GitHub repository containing this code (fork or your own copy).
- A Cloudflare account with a domain whose nameservers point to Cloudflare.
  The free plan is enough for Tunnels.
- No local installation is required; everything runs on the runner.

---

## Step by step setup

### Step 1 - Get the code into your repository

```bash
git clone https://github.com/<you>/9router.git
cd 9router
```

The workflow only needs `.github/workflows/run-9router.yml` and `scripts/`.

### Step 2 - Create a Cloudflare named tunnel

A named tunnel gives you a permanent hostname. A quick tunnel gives a random
`*.trycloudflare.com` URL that changes on every run.

1. Open <https://one.dash.cloudflare.com> and go to **Networks -> Tunnels**
   (older dashboards: **Access -> Tunnels**).
2. Click **Create a tunnel**, choose **Cloudflared**, name it (for example `9router`),
   and save.
3. The next screen shows installation commands for several platforms. You do not need
   to run any of them. Copy only the token: the long string that starts with `eyJ` in
   `cloudflared service install eyJ...`.
4. Keep the tunnel page open. It reports **Healthy** as soon as the workflow connects,
   which can only happen after Step 4.

Treat this token as a credential: anyone holding it can attach a connector to your
tunnel. If it leaks, use **Refresh token** on the tunnel page and update the secret.

### Step 3 - Add the public hostname route

Inside the tunnel, open the **Routes** tab (not Overview) and click **Add route**
(**Add public hostname**).

| Field | Value |
|---|---|
| Subdomain | `router` (or any label you prefer) |
| Domain | a domain that is active on Cloudflare |
| Path | leave empty |
| Service type | `HTTP` |
| URL | `http://localhost:20128` (a protocol is mandatory) |

Save. Cloudflare creates the DNS record automatically:

```text
Type: CNAME
Name: router.<your-domain>
Points to: <tunnel-id>.cfargotunnel.com
```

The route must point at `http://localhost:20128`, the port 9router binds to on the
runner. The tunnel process and the server run inside the same job, so `localhost`
resolves to the same machine.

### Step 4 - Add repository secrets

Go to **Settings -> Secrets and variables -> Actions -> New repository secret**.

| Secret | Required | Value |
|---|---|---|
| `ROUTER_API_KEY` | yes | Master key clients send as `Authorization: Bearer ...`. Use a long random string, at least 24 characters. |
| `CLOUDFLARE_TUNNEL_TOKEN` | yes for a stable URL | The `eyJ...` token from Step 2. |
| `PUBLIC_URL` | yes with a named tunnel | The route from Step 3, for example `https://router.example.com`. Used for printing only; the route decides where traffic lands. |
| `GEMINI_API_KEY` | if you use Gemini | One key, or several keys separated by newlines. |
| `PROVIDERS_CONF` | optional | Multi-line `provider:key` list, see below. |
| `ROUTER_PORT` | optional | Defaults to `20128`. Change the route target too if you change it. |
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`, `GROQ_API_KEY`, `OPENROUTER_API_KEY`, `MISTRAL_API_KEY`, `COHERE_API_KEY`, `MOONSHOT_API_KEY`, `TOGETHER_API_KEY`, `XAI_API_KEY`, `QWEN_API_KEY` | optional | Same multi-line rule as `GEMINI_API_KEY`. |

Only the secrets you actually need have to exist. An absent secret is an empty
variable and its provider is skipped.

### Step 5 - Run the workflow

1. Open the **Actions** tab.
2. Select **Run 9router with Cloudflare Tunnel**.
3. Click **Run workflow**, set `duration_hours` (default `6`, the maximum GitHub
   allows), and confirm.

The workflow also has a `schedule` trigger (`0 */6 * * *`). Remove that block if you
only want manual starts.

Expected log, in order:

```text
[Seeder] Target SQLite database: /home/runner/.9router/db/data.sqlite
[Seeder] Registered: gemini key #1
[Seeder] Registered: gemini key #2
[Seeder] Registered Master API Key: ...
[Seeder] Done! Successfully configured 2 AI provider(s).
9router is running and healthy!
Using named tunnel token (stable custom domain)
Public Tunnel URL : https://router.example.com
Server is running. Press Ctrl+C or cancel GitHub workflow to stop.
```

GitHub masks secret values in logs, so the URL and the master key can appear as `***`.
That is expected; the route and the secret still hold the real values.

### Step 6 - Verify it works

Health check without credentials: the server must answer with `401`, not `502`.

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://router.example.com/v1/models
# 401       -> server is up and enforcing auth
# 502/1033  -> origin down or tunnel route missing
```

List models with the master key:

```bash
curl -s https://router.example.com/v1/models \
  -H "Authorization: Bearer $ROUTER_API_KEY"
```

Send a real request:

```bash
curl -s https://router.example.com/v1/chat/completions \
  -H "Authorization: Bearer $ROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini/gemini-3.5-flash-lite",
       "messages":[{"role":"user","content":"Reply with exactly: ok"}],
       "stream":false}'
```

Model identifiers follow `provider/model`, for example `gemini/gemini-3.5-flash-lite`,
`gemini/gemini-3-flash-preview`, `openai/gpt-4o`. The exact list is whatever
`/v1/models` returns for the keys you registered.

Responses are streamed as SSE by default. Pass `"stream": false` when you want a
single JSON body.

---

## Client setup

OpenAI-compatible clients (Cursor, Cline, OpenClaw, custom scripts):

```text
Base URL : https://router.<your-domain>/v1
API Key  : the ROUTER_API_KEY secret
Model    : gemini/gemini-3.5-flash-lite  (or any id from /v1/models)
```

Claude Code:

```bash
export ANTHROPIC_BASE_URL="https://router.<your-domain>/v1"
export ANTHROPIC_API_KEY="<ROUTER_API_KEY>"
claude
```

Python with the OpenAI SDK:

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://router.<your-domain>/v1",
    api_key="<ROUTER_API_KEY>",
)

response = client.chat.completions.create(
    model="gemini/gemini-3.5-flash-lite",
    messages=[{"role": "user", "content": "Hello 9router"}],
)
print(response.choices[0].message.content)
```

---

## Configuring provider keys

Two formats are supported. Use whichever fits.

### Format A - one secret per provider, multi-line

Create `GEMINI_API_KEY` and put one key per line:

```text
AIzaSy...first
AIzaSy...second
AIzaSy...third
```

The seeder maps the variable name to a provider (`GEMINI_API_KEY` -> `gemini`,
`OPENAI_API_KEY` -> `openai`, and so on), then registers every line as a separate
connection: `conn-gemini-auto-1`, `conn-gemini-auto-2`, and so on. There is no limit
on the number of keys per provider; the numbering comes from the file, not from
hardcoded entries.

### Format B - a single `PROVIDERS_CONF` secret

One `provider:key` pair per line:

```text
gemini:AIzaSy...first
gemini:AIzaSy...second
openai:sk-proj-...
anthropic:sk-ant-...
deepseek:sk-...
```

`PROVIDERS_CONF` is read first. When it is set, the per-provider `*_API_KEY`
variables are ignored entirely.

### Resolution order in the seeder

1. The `PROVIDERS_CONF` environment variable (secret).
2. Any variable starting with `PROVIDERS_CONF_`.
3. The `providers.conf` file in the working directory (local runs only, git-ignored).
4. Individual `*_API_KEY` variables, split by newline.

Blank lines and lines starting with `#` are skipped. A line without a colon inside a
`provider:key` block is reported as malformed and skipped.

---

## Running locally (optional)

Local runs validate the parser and the startup path. They start the real server and,
without a tunnel token, a quick tunnel.

```bash
cp api_keys.env.example api_keys.env
# edit api_keys.env, then:
python3 scripts/setup-providers.py
ROUTER_PORT=20128 bash scripts/start-tunnel.sh
```

Variables that matter locally:

| Variable | Meaning |
|---|---|
| `DATA_DIR` | Where 9router keeps `db/data.sqlite`. Defaults to `~/.9router` on Linux and `%APPDATA%\9router` on Windows. |
| `ENV_FILE_PATH` | File used to fill unset variables. Default `api_keys.env`. |
| `PROVIDERS_CONF_PATH` | File used when `PROVIDERS_CONF` is unset. Default `providers.conf`. |
| `MAX_RESTARTS` | Consecutive crash restarts allowed by the watchdog. Default `5`. |
| `CLOUDFLARE_TUNNEL_TOKEN` | When set, a named tunnel is used. When empty, a quick tunnel is used. |
| `PUBLIC_URL` | Printed as the public address when the named tunnel is used. |

Rules the scripts follow:

- Variables already present in the environment always win. A local file only fills
  gaps and never overrides a secret. An unconditional `source` of a template file
  silently replaced every secret with an empty value, which is why the loop exists.
- The seeder and the server share one `DATA_DIR`. Two different data directories
  produce the classic symptom of `configured 0 providers` while the server looks
  healthy and has no keys.

---

## Runtime behavior and limits

- **Duration.** The workflow runs the supervisor under
  `timeout $((hours * 3600 - 300))`, leaving a five-minute margin before GitHub's
  six-hour job limit. When the timeout expires the job stops and the tunnel goes down
  with it.
- **Health gate.** The supervisor retries `/v1/models` for about three minutes. A first
  start on a cold runner compiles Next.js pages and can exceed two minutes. If the gate
  fails, the last 40 log lines are printed and the script exits with code 1 instead of
  publishing a URL for a dead origin.
- **Watchdog.** Every 30 seconds both child processes are checked. A dead router is
  restarted up to `MAX_RESTARTS` times; cloudflared exiting ends the job with its log.
  On exit, a `trap` kills both children.
- **Tunnel choice.** With `CLOUDFLARE_TUNNEL_TOKEN` set,
  `cloudflared tunnel run --token` connects and the hostname comes from Step 3.
  Without it, `cloudflared tunnel --url http://127.0.0.1:$PORT` creates a random
  hostname that changes on every run and can fail with HTTP 429 when Cloudflare
  rate-limits provisioning.
- **Master key.** `ROUTER_API_KEY` is written into the database as the 9router access
  key. If it is unset the scripts fall back to a placeholder value, which is not safe
  for a public URL.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Successfully configured 0 AI provider(s)` | No key reached the seeder: the secret is missing, or a template `api_keys.env` overrode the environment | Confirm the secret exists and keep the fill-gaps-only behaviour in `start-tunnel.sh` |
| One key registered from a multi-line secret, the rest reported as `malformed line` | Per-provider values must be raw keys, one per line, with no `provider:` prefix | Remove the prefix from `GEMINI_API_KEY` values, or switch to `PROVIDERS_CONF` |
| `9router did not answer within ...s` | Cold start slower than the gate, or the process crashed | Read the printed `app.log` tail; raise `HEALTH_RETRIES` if the runner is slow |
| Health check passed but Cloudflare returns 502 or "unable to resolve" | History: the tunnel was started before the origin was ready | Fixed by the hard health gate; never start the tunnel before the gate passes |
| Workflow finishes seconds after printing the URL | History: `wait $ROUTER_PID` returned when the router died | Replaced by the watchdog loop; if it still happens the router keeps crashing, check `app.log` |
| `401 API key required for remote API access` | Request sent without the master key | Add `Authorization: Bearer $ROUTER_API_KEY` |
| Upstream `401 ACCESS_TOKEN_TYPE_UNSUPPORTED` | The key is an OAuth access token, not a provider API key | Use a real API key (`AIza...` for Gemini, `sk-...` for OpenAI) |
| Upstream `429 quota exceeded`, `limit: 0` | The model is not available on the provider's free tier | Pick another model returned by `/v1/models` |
| Quick tunnel URL works, then stops | Quick tunnels have no uptime guarantee and change every run | Use a named tunnel with a route and `PUBLIC_URL` |
| Tunnel is healthy but the domain returns 404 | The route points at the wrong port or service type | Route must be `HTTP` to `http://localhost:20128` |

---

## Security notes

- Keep credentials in repository secrets. Never commit `api_keys.env`, `.env`, or
  `providers.conf`; all three are git-ignored.
- A public repository is fine as long as no key is committed, but a private one
  reduces exposure of the workflow and endpoints. Secrets work in both cases.
- Rotate `ROUTER_API_KEY` if it was shared in a chat, a commit, or a log. Use a random
  value of at least 24 characters; short values are guessable and the endpoint is
  reachable from the internet.
- The tunnel token grants connector access to your Cloudflare account. Rotate it with
  **Refresh token** if it leaks, then update `CLOUDFLARE_TUNNEL_TOKEN`.
- Anyone holding the master key plus the hostname can spend your provider quotas.
  Treat that pair as one credential.
