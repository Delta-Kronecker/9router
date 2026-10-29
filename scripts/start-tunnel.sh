#!/usr/bin/env bash
set -e

echo "============================================================"
echo "🚀 Starting 9router & Cloudflare Tunnel setup..."
echo "============================================================"

# Environment variables setup
ENV_FILE="${ENV_FILE_PATH:-api_keys.env}"
PORT="${ROUTER_PORT:-20128}"

if [ -f "$ENV_FILE" ]; then
    echo "📄 Exporting configuration from $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
fi

# Re-evaluate port if loaded from env file
PORT="${ROUTER_PORT:-20128}"

# Step 1: Seed 9router Database with configured API keys
echo "🌱 Seeding 9router database..."
python3 scripts/setup-providers.py

# Step 2: Launch 9router
echo "📡 Launching 9router service on port $PORT..."
mkdir -p /tmp/9router-logs

# Try starting 9router using npx, global binary, or local npm
if command -v 9router &> /dev/null; then
    PORT=$PORT 9router > /tmp/9router-logs/app.log 2>&1 &
elif [ -f "package.json" ]; then
    PORT=$PORT npm run dev > /tmp/9router-logs/app.log 2>&1 &
else
    PORT=$PORT npx -y 9router > /tmp/9router-logs/app.log 2>&1 &
fi

ROUTER_PID=$!
echo "9router PID: $ROUTER_PID"

# Step 3: Wait for 9router to start
echo "⏳ Waiting for 9router to respond on http://127.0.0.1:$PORT ..."
MAX_RETRIES=30
RETRY_COUNT=0
HEALTH_OK=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s "http://127.0.0.1:$PORT/" > /dev/null 2>&1 || curl -s "http://127.0.0.1:$PORT/v1/models" > /dev/null 2>&1; then
        HEALTH_OK=1
        break
    fi
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ $HEALTH_OK -eq 1 ]; then
    echo "✅ 9router is running and healthy!"
else
    echo "⚠️ 9router health check timed out, but continuing to start tunnel..."
fi

# Step 4: Ensure cloudflared is installed
if ! command -v cloudflared &> /dev/null; then
    echo "📥 Installing cloudflared binary..."
    curl -L -s https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared || \
    sudo curl -L -s https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared || true
    sudo chmod +x /usr/local/bin/cloudflared || chmod +x /usr/local/bin/cloudflared || true
fi

# Step 5: Start Cloudflare Tunnel
echo "🌐 Starting Cloudflare Tunnel..."
TUNNEL_LOG="/tmp/9router-logs/cloudflared.log"

if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
    echo "🔑 Using custom Cloudflare Tunnel Token"
    cloudflared tunnel run --token "$CLOUDFLARE_TUNNEL_TOKEN" > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!
    PUBLIC_URL="Custom Cloudflare Domain (Configured in your Cloudflare Dashboard)"
else
    echo "⚡ Spawning Cloudflare Quick Tunnel (*.trycloudflare.com)..."
    cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!
    
    echo "⏳ Waiting for Cloudflare Tunnel URL..."
    URL_FOUND=0
    for i in {1..30}; do
        if grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$TUNNEL_LOG" | head -n 1 > /tmp/tunnel_url.txt; then
            PUBLIC_URL=$(cat /tmp/tunnel_url.txt)
            if [ -n "$PUBLIC_URL" ]; then
                URL_FOUND=1
                break
            fi
        fi
        sleep 2
    done
    
    if [ $URL_FOUND -eq 0 ]; then
        echo "❌ Failed to retrieve Cloudflare Tunnel URL. Check logs:"
        cat "$TUNNEL_LOG"
        PUBLIC_URL="Tunnel creation failed. See logs."
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
wait $ROUTER_PID $TUNNEL_PID
