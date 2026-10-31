#!/usr/bin/env bash
set -e

echo "=============================================================="
echo "🚀 Starting 9router & Cloudflare Tunnel setup..."
echo "=============================================================="

# Environment variables setup.
# Secrets from the runner environment always win; a local env file only fills gaps.
ENV_FILE="${ENV_FILE_PATH:-api_keys.env}"
PORT="${ROUTER_PORT:-20128}"

if [ -f "$ENV_FILE" ]; then
    echo "📄 Filling unset config from $ENV_FILE"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        k="${line%%=*}"; v="${line#*=}"
        k="$(echo "$k" | tr -d '[:space:]')"
        v="${v%\"}"; v="${v#\"}"
        [ -z "$k" ] && continue
        [ -n "${!k}" ] && continue
        export "$k=$v"
    done < "$ENV_FILE"
fi

PORT="${ROUTER_PORT:-20128}"

# 9router stores its SQLite DB under DATA_DIR (default: ~/.9router on Linux,
# %APPDATA%\9router on Windows). Pin it so the seeder and the server always agree.
export DATA_DIR="${DATA_DIR:-$HOME/.9router}"
mkdir -p "$DATA_DIR" /tmp/9router-logs
APP_LOG="/tmp/9router-logs/app.log"

# Step 1: Seed 9router Database with configured API keys
echo "🌱 Seeding 9router database..."
python3 scripts/setup-providers.py

# Step 2: Launch 9router (no browser, no auto-update, logs visible)
echo "📡 Launching 9router service on port $PORT..."
start_router() {
    9router -n -l --skip-update -p "$PORT" -H 0.0.0.0 >> "$APP_LOG" 2>&1 &
    ROUTER_PID=$!
    echo "9router PID: $ROUTER_PID"
}

# Step 3: Wait for the HTTP port to actually answer (first boot compiles Next.js, can take minutes)
echo "⏳ Waiting for 9router to respond on http://127.0.0.1:$PORT ..."
wait_router() {
    for i in $(seq 1 ${HEALTH_RETRIES:-90}); do
        if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/v1/models" 2>/dev/null; then
            echo "✅ 9router is running and healthy!"
            return 0
        fi
        if ! kill -0 "${ROUTER_PID:-0}" 2>/dev/null; then
            echo "❌ 9router process exited. Last log lines:"
            tail -40 "$APP_LOG"
            return 1
        fi
        sleep 2
    done
    echo "❌ 9router did not answer within $(( ${HEALTH_RETRIES:-90} * 2 ))s. Last log lines:"
    tail -40 "$APP_LOG"
    return 1
}

start_router
# A dead origin means a dead tunnel: fail loudly instead of publishing a 502 URL.
wait_router || exit 1

# Step 4: Start Cloudflare Tunnel with cloudflared CLI
echo "🌐 Starting Cloudflare Tunnel..."
TUNNEL_LOG="/tmp/9router-logs/cloudflared.log"

if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
    echo "🔑 Using named tunnel token (stable custom domain)"
    cloudflared tunnel run --token "$CLOUDFLARE_TUNNEL_TOKEN" > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!

    # Named tunnels get their URL from the Public Hostname route in Cloudflare.
    PUBLIC_URL="${PUBLIC_URL:-}"
    if [ -z "$PUBLIC_URL" ]; then
        echo "⚠️ PUBLIC_URL not set. Set it to your routed hostname, e.g. https://router.example.com"
        PUBLIC_URL="(set PUBLIC_URL secret to your tunnel hostname)"
    fi
else
    echo "⚡ Spawning quick tunnel (random *.trycloudflare.com URL, changes every run)"
    cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!

    echo "⏳ Waiting for Cloudflare Tunnel URL..."
    PUBLIC_URL=""
    for i in $(seq 1 30); do
        PUBLIC_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | grep -v 'api\.' | tail -n 1 || true)
        [ -n "$PUBLIC_URL" ] && break
        sleep 2
    done

    if [ -z "$PUBLIC_URL" ]; then
        echo "❌ Failed to retrieve Cloudflare Tunnel URL. Tunnel log:"
        tail -20 "$TUNNEL_LOG"
        PUBLIC_URL="(tunnel failed)"
    fi
fi

# Step 6: Print Output Summary
MASTER_KEY="${ROUTER_API_KEY:-sk-9router-secret-key-12345}"

echo ""
echo "================================================================="
echo "🎉 9ROUTER & CLOUDFLARE TUNNEL IS RUNNING ONLINE!"
echo "================================================================="
echo "🌐 Public Tunnel URL : $PUBLIC_URL"
echo "🔗 OpenAI Base URL   : $PUBLIC_URL/v1"
echo "🔗 Anthropic Base URL: $PUBLIC_URL/v1"
echo "🔑 Master API Key    : $MASTER_KEY"
echo "================================================================="
echo ""

# Write GitHub Actions Step Summary if running in GitHub Actions
if [ -n "$GITHUB_STEP_SUMMARY" ]; then
    cat << EOF >> "$GITHUB_STEP_SUMMARY"
## 🚀 9router API Server is Online!

### 🌐 Connection Details
* **Public Tunnel URL**: \`$PUBLIC_URL\`
* **OpenAI Compatible Base URL**: \`$PUBLIC_URL/v1\`
* **Anthropic Compatible Base URL**: \`$PUBLIC_URL/v1\`
* **Master API Key**: \`$MASTER_KEY\`

### 💻 Usage Examples

#### Cursor / Cline / OpenClaw Setup:
* **OpenAI Base URL**: \`$PUBLIC_URL/v1\`
* **API Key**: \`$MASTER_KEY\`

#### Claude Code Setup:
\`\`\`bash
export ANTHROPIC_BASE_URL="$PUBLIC_URL/v1"
export ANTHROPIC_API_KEY="$MASTER_KEY"
claude
\`\`\`

#### Python OpenAI SDK Setup:
\`\`\`python
from openai import OpenAI

client = OpenAI(
    base_url="$PUBLIC_URL/v1",
    api_key="$MASTER_KEY"
)

response = client.chat.completions.create(
    model="openai/gpt-4o",
    messages=[{"role": "user", "content": "Hello 9router!"}]
)
print(response.choices[0].message.content)
\`\`\`
EOF
fi

# Keep the job alive and the origin healthy. Exits only when cancelled or the
# router dies more than MAX_RESTARTS times in a row.
echo "🟢 Server is running. Press Ctrl+C or cancel GitHub workflow to stop."
cleanup() {
    kill "$TUNNEL_PID" "$ROUTER_PID" 2>/dev/null || true
}
trap cleanup EXIT TERM INT

MAX_RESTARTS="${MAX_RESTARTS:-5}"
RESTARTS=0
while true; do
    sleep 30
    if ! kill -0 "$ROUTER_PID" 2>/dev/null; then
        RESTARTS=$((RESTARTS+1))
        echo "⚠️ 9router died (restart $RESTARTS/$MAX_RESTARTS). Restarting..."
        [ "$RESTARTS" -gt "$MAX_RESTARTS" ] && { echo "❌ Giving up after $MAX_RESTARTS restarts."; tail -40 "$APP_LOG"; exit 1; }
        start_router
        wait_router || echo "⚠️ Router still not healthy after restart"
    fi
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        echo "❌ cloudflared exited. Last lines:"; tail -20 "$TUNNEL_LOG"; exit 1
    fi
done
