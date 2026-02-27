# Neru (Lua Binary Discord Bot)

Neru is a Discord AI bot rewritten to Lua/Luvit and packaged for binary-first deployment.
Legacy Python runtime has been removed.

## What this project uses

- Runtime: Lua + Luvit
- Discord library: Discordia
- AI providers: Gemini, Groq, OpenAI
- Storage: SQLite
- Replay logs: JSONL

## Storage layout (separate DB folder)

All SQLite files are kept in `storage/db`, separated from logs in `storage/log`.

```text
storage/
  db/
    chat_memory.db
    ban_control.db
    callnames.db
  log/
    chat_replay.jsonl
```

Defaults are configured in `.env.example`:

- `CHAT_MEMORY_DB_PATH=storage/db/chat_memory.db`
- `BAN_DB_PATH=storage/db/ban_control.db`
- `CALLNAMES_DB_PATH=storage/db/callnames.db`
- `CHAT_REPLAY_LOG_PATH=storage/log/chat_replay.jsonl`

## Quick start (WSL recommended)

From the project root (not `~`):

```bash
cd /mnt/c/Users/komekokomi/Desktop/Neru
chmod +x lit luvi luvit scripts/build-binary.sh
cp .env.example .env
./lit install
./luvit main.lua
```

Then set values in `.env`:

- `DISCORD_TOKEN` (required)
- `LLM_PROVIDER` = `gemini` | `groq` | `openai` | `chatgpt` (alias of `openai`)
- API key for the selected provider (`GEMINI_API_KEY` / `GROQ_API_KEY` / `OPENAI_API_KEY`)
- `BOT_OWNER_ID` for owner-only commands

Notes:

- `SYSTEM_PROMPT` defaults to Neru persona.
- Internal reasoning tags like `<think>` are blocked by system prompt + output sanitizing.

## Run as single binary

WSL/Linux:

```bash
./scripts/build-binary.sh neru
./neru
```

Windows native (`neru.exe`):

```powershell
.\scripts\build-binary.ps1 -OutputName neru.exe
.\neru.exe
```

If you use the bundled `lit/luvi/luvit` files from this repo, they are Linux ELF binaries, so build/run them in WSL.
For native Windows `.exe`, use Windows-native `lit/luvi` binaries.

## Commands (prefix default: `!`)

Chat:

- `!chat <text>`
- `!ask <text>` (alias)
- Mention the bot: `@Neru <text>`

Memory/runtime:

- `!clearmemo`
- `!resetchat` (alias)
- `!terminated on|off|status`
- `!provider`

Owner only:

- `!replayneru ls`
- `!replayneru <id>`
- `!replayneru<id>` (inline form)
- `!ban @user [reason]`
- `!removeban @user`

Call-name profile:

- `!ucallneru <name>` or `!callneru <name>`
- `!nerucallu <name>` or `!callme <name>`
- `!nerumention` or `!callprofile`

## Migration notes

- Legacy Python files were removed from runtime.
- Call-name storage auto-migrates old `*_miku` columns into `*_neru` columns on startup.

## Troubleshooting

- `luvit: command not found`:
  use `./luvit main.lua` from project root.
- `lit: command not found`:
  use `./lit install` from project root.
- `Permission denied` in WSL:
  run `chmod +x lit luvi luvit scripts/build-binary.sh`.
- `Missing DISCORD_TOKEN` or provider key errors:
  check `.env` values.

## Discord setup

In Discord Developer Portal:

- Enable `MESSAGE CONTENT INTENT`

Recommended bot permissions:

- View Channels
- Send Messages
- Read Message History

## License

MIT License. See `LICENSE`.
