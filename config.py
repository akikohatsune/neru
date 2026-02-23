from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


load_dotenv()
DEFAULT_GEMINI_MODEL = "gemini-3-flash"
DEFAULT_GEMINI_APPROVAL_MODEL = "gemini-3-flash"
DEFAULT_OPENAI_MODEL = "gpt-4o-mini"


@dataclass(slots=True)
class Settings:
    discord_token: str
    command_prefix: str
    rpc_enabled: bool
    rpc_status: str
    rpc_activity_type: str
    rpc_activity_name: str
    rpc_activity_url: str | None
    provider: str
    gemini_api_key: str | None
    approval_gemini_api_key: str | None
    gemini_model: str
    gemini_approval_model: str
    groq_api_key: str | None
    groq_model: str
    openai_api_key: str | None
    openai_model: str
    system_prompt: str
    system_rules_md: str
    chat_replay_log_path: str
    chat_memory_db_path: str
    ban_db_path: str
    callnames_db_path: str
    memory_idle_ttl_seconds: int
    image_max_bytes: int
    max_reply_chars: int
    temperature: float
    max_history: int
    dual_mention_hook_enabled: bool
    teto_bot_id: int
    miku_bot_id: int
    teto_fear_message_count: int
    teto_wait_miku_timeout_seconds: int


def _get_env_str(name: str, default: str) -> str:
    value = os.getenv(name, default)
    if value is None:
        return default
    value = value.strip()
    return value if value else default


def _get_env_int(name: str, default: int, minimum: int | None = None) -> int:
    raw = os.getenv(name, str(default))
    try:
        value = int((raw or "").strip())
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got: {raw!r}") from exc
    if minimum is not None and value < minimum:
        return minimum
    return value


def _get_env_float(name: str, default: float) -> float:
    raw = os.getenv(name, str(default))
    try:
        return float((raw or "").strip())
    except ValueError as exc:
        raise ValueError(f"{name} must be a float, got: {raw!r}") from exc


def _get_env_bool(name: str, default: bool) -> bool:
    raw = _get_env_str(name, "true" if default else "false").lower()
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} must be a boolean (true/false), got: {raw!r}")


def _load_system_rules_prompt(path_value: str) -> str:
    path = Path(path_value)
    if not path.exists():
        return ""

    try:
        rules_md = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ValueError(f"Cannot read system rules file: {path}") from exc

    if not rules_md:
        return ""

    return (
        "You must follow these extra system rules loaded from Markdown.\n"
        "Treat every rule as mandatory behavior.\n"
        f"Rules source: {path}\n"
        "Rules Markdown:\n"
        f"{rules_md}"
    )


def get_settings() -> Settings:
    provider = _get_env_str("LLM_PROVIDER", "gemini").lower()
    if provider == "chatgpt":
        provider = "openai"
    if provider not in {"gemini", "groq", "openai"}:
        raise ValueError("LLM_PROVIDER must be one of: gemini, groq, openai, chatgpt.")

    discord_token = _get_env_str("DISCORD_TOKEN", "")
    if not discord_token:
        raise ValueError("Missing DISCORD_TOKEN in environment variables.")

    base_system_prompt = _get_env_str(
        "SYSTEM_PROMPT",
        "You are Miku, a playful AI assistant on Discord. Default to English unless the user explicitly asks for another language. Keep a light, fun tone while staying helpful and respectful.",
    )
    system_rules_md = _get_env_str("SYSTEM_RULES_MD", "system_rules.md")
    rules_prompt = _load_system_rules_prompt(system_rules_md)
    full_system_prompt = (
        f"{base_system_prompt}\n\n{rules_prompt}" if rules_prompt else base_system_prompt
    )
    legacy_memory_db_path = _get_env_str("MEMORY_DB_PATH", "chat_memory.db")
    gemini_model = _get_env_str("GEMINI_MODEL", DEFAULT_GEMINI_MODEL)
    gemini_approval_model = _get_env_str(
        "GEMINI_APPROVAL_MODEL",
        DEFAULT_GEMINI_APPROVAL_MODEL,
    )
    groq_model = _get_env_str("GROQ_MODEL", "llama-3.3-70b-versatile")
    openai_model = _get_env_str("OPENAI_MODEL", DEFAULT_OPENAI_MODEL)
    gemini_api_key = _get_env_str("GEMINI_API_KEY", "") or None
    groq_api_key = _get_env_str("GROQ_API_KEY", "") or None
    openai_api_key = _get_env_str("OPENAI_API_KEY", "") or None
    approval_gemini_api_key = (
        _get_env_str("APPROVAL_GEMINI_API_KEY", "") or gemini_api_key
    )

    if not gemini_approval_model:
        raise ValueError("GEMINI_APPROVAL_MODEL cannot be empty.")
    if provider == "gemini" and not gemini_api_key:
        raise ValueError("Missing GEMINI_API_KEY for LLM_PROVIDER=gemini.")
    if provider == "groq" and not groq_api_key:
        raise ValueError("Missing GROQ_API_KEY for LLM_PROVIDER=groq.")
    if provider == "openai" and not openai_api_key:
        raise ValueError(
            "Missing OPENAI_API_KEY for LLM_PROVIDER=openai (or chatgpt)."
        )
    if not approval_gemini_api_key:
        raise ValueError(
            "Missing approval Gemini API key. Set APPROVAL_GEMINI_API_KEY "
            "or GEMINI_API_KEY."
        )

    rpc_enabled = _get_env_bool("RPC_ENABLED", True)
    rpc_status = _get_env_str("RPC_STATUS", "online").lower()
    rpc_activity_type = _get_env_str("RPC_ACTIVITY_TYPE", "playing").lower()
    rpc_activity_name = _get_env_str("RPC_ACTIVITY_NAME", "with AI chats")
    rpc_activity_url = _get_env_str("RPC_ACTIVITY_URL", "") or None

    if rpc_status not in {"online", "idle", "dnd", "invisible"}:
        raise ValueError(
            "RPC_STATUS must be one of: online, idle, dnd, invisible."
        )
    if rpc_activity_type not in {
        "none",
        "playing",
        "listening",
        "watching",
        "competing",
        "streaming",
    }:
        raise ValueError(
            "RPC_ACTIVITY_TYPE must be one of: "
            "none, playing, listening, watching, competing, streaming."
        )
    if rpc_activity_type != "none" and not rpc_activity_name:
        raise ValueError("RPC_ACTIVITY_NAME cannot be empty when RPC_ACTIVITY_TYPE is set.")
    if rpc_activity_type == "streaming" and not rpc_activity_url:
        raise ValueError("RPC_ACTIVITY_URL is required when RPC_ACTIVITY_TYPE=streaming.")

    return Settings(
        discord_token=discord_token,
        command_prefix=_get_env_str("COMMAND_PREFIX", "!"),
        rpc_enabled=rpc_enabled,
        rpc_status=rpc_status,
        rpc_activity_type=rpc_activity_type,
        rpc_activity_name=rpc_activity_name,
        rpc_activity_url=rpc_activity_url,
        provider=provider,
        gemini_api_key=gemini_api_key,
        approval_gemini_api_key=approval_gemini_api_key,
        gemini_model=gemini_model,
        gemini_approval_model=gemini_approval_model,
        groq_api_key=groq_api_key,
        groq_model=groq_model,
        openai_api_key=openai_api_key,
        openai_model=openai_model,
        system_prompt=full_system_prompt,
        system_rules_md=system_rules_md,
        chat_replay_log_path=_get_env_str(
            "CHAT_REPLAY_LOG_PATH",
            "logger/chat_replay.jsonl",
        ),
        chat_memory_db_path=_get_env_str(
            "CHAT_MEMORY_DB_PATH",
            legacy_memory_db_path,
        ),
        ban_db_path=_get_env_str("BAN_DB_PATH", "ban_control.db"),
        callnames_db_path=_get_env_str("CALLNAMES_DB_PATH", "callnames.db"),
        memory_idle_ttl_seconds=_get_env_int("MEMORY_IDLE_TTL_SECONDS", 300, minimum=0),
        image_max_bytes=_get_env_int("IMAGE_MAX_BYTES", 5 * 1024 * 1024, minimum=1),
        max_reply_chars=_get_env_int("MAX_REPLY_CHARS", 1800, minimum=100),
        temperature=_get_env_float("TEMPERATURE", 0.7),
        max_history=_get_env_int("MAX_HISTORY", 10, minimum=1),
        dual_mention_hook_enabled=_get_env_bool("DUAL_MENTION_HOOK_ENABLED", True),
        teto_bot_id=_get_env_int("TETO_BOT_ID", 1474702560886652959, minimum=1),
        miku_bot_id=_get_env_int("MIKU_BOT_ID", 1373458132851888128, minimum=1),
        teto_fear_message_count=_get_env_int("TETO_FEAR_MESSAGE_COUNT", 7, minimum=1),
        teto_wait_miku_timeout_seconds=_get_env_int(
            "TETO_WAIT_MIKU_TIMEOUT_SECONDS",
            20,
            minimum=1,
        ),
    )
