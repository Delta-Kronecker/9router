#!/usr/bin/env bash
set -e

echo "=============================================================="
echo "🚀 Starting 9router & Cloudflare Tunnel setup..."
echo "=============================================================="

# Environment variables setup
ENV_FILE="${ENV_FILE_PATH:-api_keys.env}"
PORT="${ROUTER_PORT:-20128}"

if [ -f "$ENV_FILE" ]; then
    echo "📄 Exporting configuration from $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
fi

PORT="${ROUTER_PORT:-20128}"

# Step 1: Seed 9router Database with configured API keys
echo "🌱 Seeding 9router database..."
python3 scripts/setup-providers.py

# Step 2: Launch 9router with built-in tunnel support
echo "📡 Launching 9router service on port $PORT..."
mkdir -p /tmp/9router-logs

# Start 9router in background
PORT=$PORT 9router > /tmp/9router-logs/app.log 2>&1 &
ROUTER_PID=$!
echo "9router PID: $ROUTER_PID"

# Step 3: Wait for 9router to start
echo "⏳ Waiting for 9router to respond on http://127.0.0.1:$PORT ..."
MAX_RETRIES=60
RETRY_COUNT=0
HEALTH_OK=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s "http://127.0.0.1:$PORT/v1/models" > /dev/null 2>&1; then
        HEALTH_OK=1
        break
    fi
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ $HEALTH_OK -eq 1 ]; then
    echo "✅ 9router is running and healthy!"
else
    echo "⚠️ 9router health check timed out, but continuing..."
fi

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

# Keep workflow alive
echo "🟢 Server is running. Press Ctrl+C or cancel GitHub workflow to stop."
wait $ROUTER_PID
