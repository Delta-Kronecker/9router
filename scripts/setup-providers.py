#!/usr/bin/env python3
"""
9router SQLite Seeder Script
-----------------------------
This script reads API keys and configuration from environment variables or `api_keys.env`,
ensures the 9router SQLite database schema exists, and injects active provider connections
and access keys into the 9router database (~/.9router/db/data.sqlite or $DATA_DIR/db/data.sqlite).
"""

import os
import sys
import json
import sqlite3
from datetime import datetime, timezone

ENV_PROVIDER_MAP = {
    "GEMINI": "gemini",
    "OPENAI": "openai",
    "ANTHROPIC": "anthropic",
    "DEEPSEEK": "deepseek",
    "GROQ": "groq",
    "OPENROUTER": "openrouter",
    "MISTRAL": "mistral",
    "COHERE": "cohere",
    "MOONSHOT": "moonshot",
    "TOGETHER": "together",
    "XAI": "xai",
    "QWEN": "qwen",
    "PERPLEXITY": "perplexity",
    "OLLAMA": "ollama",
    "AZURE": "azure",
    "CEREBRAS": "cerebras",
}

def provider_from_env_name(env_key):
    """Map an env var name like GEMINI_API_KEY or GEMINI_API_KEY_2 to a provider id."""
    name = env_key
    if name.endswith("_API_KEY"):
        name = name[: -len("_API_KEY")]
    elif "_API_KEY_" in name:
        name = name.split("_API_KEY_", 1)[0]
    else:
        return None
    return ENV_PROVIDER_MAP.get(name.strip().upper())

def load_env_file(filepath):
    """Parses key=value pairs from a file into os.environ if not already set."""
    if not os.path.exists(filepath):
        print(f"[Seeder] Note: {filepath} not found. Using system environment variables.")
        return
    
    print(f"[Seeder] Loading environment file: {filepath}")
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            key = key.strip()
            val = val.strip().strip("'\"")
            if key and not os.getenv(key):
                os.environ[key] = val

def resolve_db_path():
    """Resolves the path to 9router data.sqlite file."""
    data_dir = os.getenv("DATA_DIR")
    if not data_dir:
        home = os.path.expanduser("~")
        data_dir = os.path.join(home, ".9router")
    
    db_dir = os.path.join(data_dir, "db")
    os.makedirs(db_dir, exist_ok=True)
    return os.path.join(db_dir, "data.sqlite")

def init_db_schema(conn):
    """Ensures required tables exist in the 9router database."""
    cursor = conn.cursor()
    
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS providerConnections (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        authType TEXT NOT NULL,
        name TEXT,
        email TEXT,
        priority INTEGER,
        isActive INTEGER NOT NULL DEFAULT 1,
        data TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
    )
    """)
    
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS apiKeys (
        id TEXT PRIMARY KEY,
        key TEXT NOT NULL,
        name TEXT,
        machineId TEXT,
        isActive INTEGER NOT NULL DEFAULT 1,
        createdAt TEXT NOT NULL
    )
    """)
    
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS settings (
        id INTEGER PRIMARY KEY,
        data TEXT NOT NULL
    )
    """)
    
    conn.commit()

def seed_database():
    env_path = os.getenv("ENV_FILE_PATH", "api_keys.env")
    load_env_file(env_path)
    
    db_path = resolve_db_path()
    print(f"[Seeder] Target SQLite database: {db_path}")
    
    conn = sqlite3.connect(db_path)
    init_db_schema(conn)
    cursor = conn.cursor()
    
    now_iso = datetime.now(timezone.utc).isoformat()
    
    # providers.conf format: one "provider:key" per line, multiple keys per provider allowed.
    # Source: PROVIDERS_CONF env var (GitHub secret) or providers.conf / api_keys.env files.
    conf_source = os.getenv("PROVIDERS_CONF", "")
    if not conf_source:
        for key, val in os.environ.items():
            if key.startswith("PROVIDERS_CONF_"):
                conf_source += val + "\n"

    # Fall back to providers.conf file on disk (local testing)
    if not conf_source:
        conf_path = os.getenv("PROVIDERS_CONF_PATH", "providers.conf")
        if os.path.exists(conf_path):
            print(f"[Seeder] Reading providers from {conf_path}")
            with open(conf_path, "r", encoding="utf-8") as f:
                conf_source = f.read()
        else:
            print("[Seeder] Note: PROVIDERS_CONF not set and no providers.conf found.")

    # Fall back to individual *_API_KEY secrets, e.g. GEMINI_API_KEY, GEMINI_API_KEY_2, OPENAI_API_KEY...
    if not conf_source:
        for env_key, val in os.environ.items():
            prov = provider_from_env_name(env_key)
            if prov and val.strip():
                conf_source += f"{prov}:{val.strip()}\n"

    configured_count = 0
    seen = {}
    for lineno, raw in enumerate(conf_source.splitlines(), 1):
        entry = raw.strip()
        if not entry or entry.startswith("#"):
            continue
        if ":" not in entry:
            print(f"[Seeder] Warning: skipping malformed line {lineno} (expected provider:key)")
            continue
        provider_id, api_key = entry.split(":", 1)
        provider_id = provider_id.strip().lower()
        api_key = api_key.strip()
        if not api_key:
            continue

        seen[provider_id] = seen.get(provider_id, 0) + 1
        conn_id = f"conn-{provider_id}-auto-{seen[provider_id]}"
        connection_data = json.dumps({
            "apiKey": api_key,
            "providerSpecificData": {}
        })
        display_name = f"{provider_id.capitalize()} (auto-{seen[provider_id]})"

        cursor.execute("""
        INSERT INTO providerConnections (id, provider, authType, name, priority, isActive, data, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            provider=excluded.provider,
            data=excluded.data,
            isActive=1,
            updatedAt=excluded.updatedAt
        """, (conn_id, provider_id, "apiKey", display_name, seen[provider_id], connection_data, now_iso, now_iso))

        print(f"[Seeder] Registered: {provider_id} key #{seen[provider_id]}")
        configured_count += 1

    # Master API Key configuration
    master_key = os.getenv("ROUTER_API_KEY", "").strip()
    if master_key:
        cursor.execute("""
        INSERT INTO apiKeys (id, key, name, isActive, createdAt)
        VALUES ('key-master-auto', ?, 'GitHub Actions Master Key', 1, ?)
        ON CONFLICT(id) DO UPDATE SET
            key=excluded.key,
            createdAt=excluded.createdAt
        """, (master_key, now_iso))
        print(f"[Seeder] Registered Master API Key: {master_key[:8]}...")

    conn.commit()
    conn.close()
    
    print(f"[Seeder] Done! Successfully configured {configured_count} AI provider(s).")

if __name__ == "__main__":
    seed_database()
