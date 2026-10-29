# 🚀 9router on GitHub Actions with Cloudflare Tunnel

Run **9router** on GitHub Actions with **Cloudflare Tunnel** for public, secure access to your AI models and provider endpoints.

---

## 🌟 Features

1. **Hosted on GitHub Actions**: Runs on GitHub runners without needing your own VPS or server.
2. **Multi-Provider Support**: Store all your AI provider keys (OpenAI, Anthropic, Gemini, DeepSeek, Groq, OpenRouter, Mistral, Moonshot, etc.) in a single configuration file (`api_keys.env`) or GitHub Secrets.
3. **Cloudflare Tunnel Integration**: Automatically spawns a secure public HTTPS endpoint (`https://xxxx.trycloudflare.com`) to connect tools like Cursor, Claude Code, Cline, OpenClaw, etc.
4. **Automated Database Seeding**: Auto-configures 9router's SQLite database with active providers and master access keys.

---

## 📁 Project Structure

```text
.
├── .github/
│   └── workflows/
│       └── run-9router.yml    # Main GitHub Actions Workflow
├── scripts/
│   ├── setup-providers.py    # Database seeder & API key parser
│   └── start-tunnel.sh       # Service runner & Cloudflare Tunnel manager
├── api_keys.env.example      # Example environment configuration
├── api_keys.env              # Active environment configuration
├── .gitignore
└── README.md
```

---

## 🚀 Quick Start Guide

### Option 1: Using GitHub Secrets (Recommended)

1. Push or fork this repository to your GitHub account.
2. Go to **Settings > Secrets and variables > Actions** in your GitHub repository.
3. Add your provider API keys (e.g., `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`, `ROUTER_API_KEY`, etc.).
4. Navigate to the **Actions** tab, select **Run 9router with Cloudflare Tunnel**, and click **Run workflow**.

### Option 2: Using `api_keys.env` File

1. Copy the template file:
   ```bash
   cp api_keys.env.example api_keys.env
   ```
2. Open `api_keys.env` and fill in your API keys:
   ```env
   ROUTER_PORT=20128
   ROUTER_API_KEY=sk-9router-secret-key-12345

   OPENAI_API_KEY=sk-proj-...
   ANTHROPIC_API_KEY=sk-ant-...
   GEMINI_API_KEY=AIzaSy...
   DEEPSEEK_API_KEY=sk-...
   GROQ_API_KEY=gsk_...
   ```
3. Commit and push your changes to GitHub (Note: `api_keys.env` is ignored by `.gitignore` to prevent accidental credential leaks).

---

## 🌐 Connecting to the Cloudflare Tunnel

When the GitHub Workflow starts, your public URL will be printed in the **Actions Summary** and job logs:

```text
=================================================================
🎉 9ROUTER & CLOUDFLARE TUNNEL IS RUNNING ONLINE!
=================================================================
🌐 Public Tunnel URL : https://abc123xyz.trycloudflare.com
🔗 OpenAI Base URL   : https://abc123xyz.trycloudflare.com/v1
🔗 Anthropic Base URL: https://abc123xyz.trycloudflare.com/v1
🔑 Master API Key    : sk-9router-secret-key-12345
=================================================================
```

### Cursor / Cline / OpenClaw Setup
- **OpenAI Base URL**: `https://abc123xyz.trycloudflare.com/v1`
- **API Key**: `sk-9router-secret-key-12345` (or your custom `ROUTER_API_KEY`)

### Claude Code CLI Setup
```bash
export ANTHROPIC_BASE_URL="https://abc123xyz.trycloudflare.com/v1"
export ANTHROPIC_API_KEY="sk-9router-secret-key-12345"
claude
```

### Python OpenAI SDK Setup
```python
from openai import OpenAI

client = OpenAI(
    base_url="https://abc123xyz.trycloudflare.com/v1",
    api_key="sk-9router-secret-key-12345"
)

response = client.chat.completions.create(
    model="openai/gpt-4o",
    messages=[{"role": "user", "content": "Hello 9router!"}]
)

print(response.choices[0].message.content)
```

---

## 🛠️ Local Testing

To test the scripts locally before pushing:

```bash
# Seed database
python3 scripts/setup-providers.py

# Start service & tunnel
bash scripts/start-tunnel.sh
```
