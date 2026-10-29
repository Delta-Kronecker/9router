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
    
    # Map of env var -> 9router provider identifier & display name
    provider_mappings = [
        ("OPENAI_API_KEY", "openai", "OpenAI"),
        ("ANTHROPIC_API_KEY", "anthropic", "Anthropic Claude"),
        ("GEMINI_API_KEY", "gemini", "Google Gemini"),
        ("DEEPSEEK_API_KEY", "deepseek", "DeepSeek"),
        ("GROQ_API_KEY", "groq", "Groq"),
        ("OPENROUTER_API_KEY", "openrouter", "OpenRouter"),
        ("MISTRAL_API_KEY", "mistral", "Mistral AI"),
        ("COHERE_API_KEY", "cohere", "Cohere"),
        ("MOONSHOT_API_KEY", "moonshot", "Moonshot (Kimi)"),
        ("TOGETHER_API_KEY", "together", "Together AI"),
        ("XAI_API_KEY", "xai", "xAI (Grok)"),
        ("QWEN_API_KEY", "qwen", "Alibaba Qwen"),
    ]
    
    configured_count = 0
    for env_var, provider_id, display_name in provider_mappings:
        api_key = os.getenv(env_var, "").strip()
        if not api_key:
            continue
        
        conn_id = f"conn-{provider_id}-auto"
        connection_data = json.dumps({
            "apiKey": api_key,
            "providerSpecificData": {}
        })
        
        cursor.execute("""
        INSERT INTO providerConnections (id, provider, authType, name, priority, isActive, data, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            provider=excluded.provider,
            data=excluded.data,
            updatedAt=excluded.updatedAt
        """, (conn_id, provider_id, "apiKey", display_name, 1, connection_data, now_iso, now_iso))
        
        print(f"[Seeder] Registered provider: {display_name} ({provider_id})")
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
