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

**Default personality:**
- Miku is playful, friendly, and helpful.
- Default response language is English (unless the user asks for another language).

## 1) Setup

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 2) Configuration

```bash
cp .env.example .env
```

Edit `.env`:
- `DISCORD_TOKEN`: Discord bot token
- `LLM_PROVIDER`: `gemini` or `groq`
- `APPROVAL_PROVIDER`: separate provider for call-name approval (`gemini` or `groq`)
- `GEMINI_API_KEY`: required when `LLM_PROVIDER=gemini` or `APPROVAL_PROVIDER=gemini`
- `GEMINI_MODEL`: must be `gemini-3-flash`
- `GEMINI_APPROVAL_MODEL`: must be `gemini-3-flash`
- `GROQ_API_KEY`: required when `LLM_PROVIDER=groq` or `APPROVAL_PROVIDER=groq`
- `GROQ_MODEL`: Groq model name
- `GROQ_APPROVAL_MODEL`: model used when `APPROVAL_PROVIDER=groq`
- `SYSTEM_PROMPT`: default Miku personality/instructions
- `SYSTEM_RULES_JSON`: JSON file for extra system rules
- `CHAT_REPLAY_LOG_PATH`: replay log file path (default `logger/chat_replay.jsonl`)
- `CHAT_MEMORY_DB_PATH`: SQLite DB for chat memory
- `BAN_DB_PATH`: SQLite DB for ban/removeban data
- `CALLNAMES_DB_PATH`: SQLite DB for naming preferences
- `MEMORY_DB_PATH`: legacy fallback for `CHAT_MEMORY_DB_PATH`
- `MEMORY_IDLE_TTL_SECONDS`: auto-clear idle short-term memory
- `IMAGE_MAX_BYTES`: max image upload size for vision input
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

Ban control:
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
- Approval provider is independent from main chat provider (`APPROVAL_PROVIDER`).
- Approval model must return only `có` (yes) or `ko` (no).
- The name is saved only when the result is `có` (yes).

## 6) System Rules JSON

Bot loads extra rules from `SYSTEM_RULES_JSON` and appends them to system prompt.

- To force a response format, edit `response_form`.
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

## License
MIT License — see `LICENSE` for details.
