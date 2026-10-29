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

# Step 4: Enable tunnel via 9router internal API
echo "🌐 Starting Cloudflare Tunnel via 9router..."

if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
    echo "🔑 Using named Cloudflare Tunnel token"
    TUNNEL_RESPONSE=$(curl -s -X POST "http://127.0.0.1:$PORT/api/tunnel/enable" \
        -H "Content-Type: application/json" \
        -d "{\"tunnelUrl\":\"https://tunnel.example.com\",\"tunnelProvider\":\"cloudflare\",\"tunnelDashboardAccess\":false}")
    echo "Tunnel enable response: $TUNNEL_RESPONSE"
    sleep 15
else
    echo "⚡ Spawning Cloudflare Quick Tunnel via 9router"
    QUICK_TUNNEL_RESPONSE=$(curl -s -X POST "http://127.0.0.1:$PORT/api/tunnel/enable" \
        -H "Content-Type: application/json" \
        -d "{\"tunnelUrl\":\"quick://\",\"tunnelProvider\":\"cloudflare\",\"tunnelDashboardAccess\":false}")
    echo "Quick tunnel enable response: $QUICK_TUNNEL_RESPONSE"
    sleep 15
fi

# Step 5: Get tunnel URL status
echo "⏳ Checking tunnel status..."
TUNNEL_STATUS=$(curl -s "http://127.0.0.1:$PORT/api/tunnel/status" 2>/dev/null || echo "{}")
echo "Tunnel status: $TUNNEL_STATUS"

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
