<p align="center">
  <img src="miku.jpg" alt="MikuMaintaining" width="500">
</p>
<p align="center"><span style="color:#8a8f98;">"39!"</span></p>

<h1 align="center">MikuMaid_reborn</h1> 

**MikuMaid_reborn** is my rewrite/replacement for a legacy API I used in earlier versions.  
This project focuses on:
- reducing technical debt and improving maintainability
- providing a consistent, well-defined API surface
- making future features easier to ship without breaking existing behavior

## Miku used

**Supported providers:**
- Gemini
- Groq

**SDKs:**
- `google-genai` for Gemini
- `groq` for Groq

**Default personality:**
- Miku is playful, friendly, and helpful.
- Miku replies in the same language as the user's latest message.

## 1) Setup

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Termux note:
- Official SDK dependencies may require Rust/C toolchain on some Termux Python builds (for `pydantic-core` / `cryptography`).

## 2) Configuration

```bash
cp .env.example .env
```

Edit `.env`:
- `DISCORD_TOKEN`: Discord bot token
- `RPC_ENABLED`: enable/disable Discord RPC presence (`true`/`false`)
- `RPC_STATUS`: `online`, `idle`, `dnd`, or `invisible`
- `RPC_ACTIVITY_TYPE`: `none`, `playing`, `listening`, `watching`, `competing`, or `streaming`
- `RPC_ACTIVITY_NAME`: activity text shown in Discord presence
- `RPC_ACTIVITY_URL`: required only when `RPC_ACTIVITY_TYPE=streaming`
- `LLM_PROVIDER`: `gemini` or `groq`
- `GEMINI_API_KEY`: required when `LLM_PROVIDER=gemini`
- `APPROVAL_GEMINI_API_KEY`: optional dedicated key for call-name approval (fallback: `GEMINI_API_KEY`)
- `GEMINI_MODEL`: Gemini model for chat (customizable, default `gemini-3-flash`)
- `GEMINI_APPROVAL_MODEL`: Gemini model for call-name approval (customizable, default `gemini-3-flash`)
- `GROQ_API_KEY`: required when `LLM_PROVIDER=groq`
- `GROQ_MODEL`: Groq model name
- `SYSTEM_PROMPT`: default Miku personality/instructions
- `SYSTEM_RULES_JSON`: JSON file for extra system rules
- `CHAT_REPLAY_LOG_PATH`: replay log file path (default `logger/chat_replay.jsonl`)
- `CHAT_MEMORY_DB_PATH`: SQLite DB for chat memory
- `BAN_DB_PATH`: SQLite DB for ban/removeban data
- `CALLNAMES_DB_PATH`: SQLite DB for naming preferences
- `MEMORY_DB_PATH`: legacy fallback for `CHAT_MEMORY_DB_PATH`
- `MEMORY_IDLE_TTL_SECONDS`: auto-clear idle short-term memory
- `IMAGE_MAX_BYTES`: max image upload size for vision input
- `MAX_REPLY_CHARS`: maximum characters per Discord message chunk (auto-split and continue when exceeded)
- `TEMPERATURE`: model temperature
- `MAX_HISTORY`: max short-term conversation turns

## 3) Run

```bash
python main.py
```

## 4) Commands

Chat:
- Tag bot (`@Bot`) + text
- `/chat <text>`
- `!chat <text>`
- `!chat <text>` + image attachment (vision)
- `!ask <text>` (alias)

Memory and runtime:
- `!clearmemo` (alias: `!resetchat`)
- `!terminated on|off|status`
- `!provider`

Ban control (bot owner only):
- `!ban @user [reason]`
- `!removeban @user`
- `/ban`, `/removeban`

Call-name preferences:
- `!ucallmiku <name>` / `/ucallmiku`
- `!mikucallu <name>` / `/mikucallu`
- `!mikumention` / `/mikumention`

Replay logger (bot owner only):
- `!replaymiku ls`
- `!replaymiku <id>`
- `!replaymiku<id>` (inline form)

## 5) Call-Name Approval

`ucallmiku` and `mikucallu` are moderated by a separate approval check.
- Approval always uses Gemini.
- Approval model comes from `GEMINI_APPROVAL_MODEL`.
- Approval model must return only `yes` or `no`.
- The name is saved only when the result is `yes`.

## 6) System Rules JSON

Bot loads extra rules from `SYSTEM_RULES_JSON` and appends them to system prompt.

- To force a response format, edit `response_form`.
- To stop LaTeX in math replies, add a rule that requires plain-text math notation.
- To disable rules temporarily, set `"enabled": false`.

## 7) Storage Isolation by Cog

Each cog uses a separate SQLite database to reduce blast radius.
If one DB is corrupted/unavailable, other cogs can keep working.

- Chat memory DB: `CHAT_MEMORY_DB_PATH`
- Ban DB: `BAN_DB_PATH`
- Call-names DB: `CALLNAMES_DB_PATH`

## 8) Replay Logger

Chat replay logs are written as JSONL in `logger/`.

- Default file: `logger/chat_replay.jsonl`
- Config key: `CHAT_REPLAY_LOG_PATH`

## 9) Discord Permissions / Intents

In Discord Developer Portal:
- Enable `MESSAGE CONTENT INTENT`

Recommended bot permissions:
- Read Messages / View Channels
- Send Messages
- Read Message History

## 10) Discord RPC Presence

The bot applies RPC presence on startup (`on_ready`) using:
- `RPC_ENABLED`
- `RPC_STATUS`
- `RPC_ACTIVITY_TYPE`
- `RPC_ACTIVITY_NAME`
- `RPC_ACTIVITY_URL` (streaming only)

## License
MIT License — see `LICENSE` for details.

Art by [gomya0_0](https://x.com/gomya0_0)
