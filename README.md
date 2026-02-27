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

## Linux/WSL tutorial (fresh clone)

Clone and enter project directory:

```bash
git clone https://github.com/akikohatsune/neru.git neru
cd neru
```

Then run setup from the project root (not `~`):

```bash
chmod +x scripts/bootstrap-luvit.sh scripts/build-binary.sh
cp .env.example .env
./scripts/bootstrap-luvit.sh
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

If you bootstrap `lit/luvi/luvit` inside WSL/Linux, they are Linux ELF binaries, so build/run them in WSL.
For native Windows `.exe`, use Windows-native `lit/luvi` binaries.

## Dependency bootstrap (lit/luvi/luvit)

`lit`, `luvi`, `luvit` are local toolchain files and may not exist after fresh clone.
Use:

```bash
./scripts/bootstrap-luvit.sh
```

Advanced:

- Force re-download/rebuild: `./scripts/bootstrap-luvit.sh --force`
- Pin versions with env vars: `LUVI_VERSION=2.14.0 LIT_VERSION=3.8.5 ./scripts/bootstrap-luvit.sh`

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
  run `./scripts/bootstrap-luvit.sh`, then `./luvit main.lua`.
- `lit: command not found`:
  run `./scripts/bootstrap-luvit.sh`, then `./lit install`.
- `./lit: No such file or directory`:
  you are likely in the wrong directory; first `pwd`, then `cd` to project root and re-run bootstrap.
- `module 'lsqlite3' not found`:
  install SQLite runtime deps, then install Lua module for Lua 5.1/LuaJIT:

  ```bash
  sudo apt update
  sudo apt install -y build-essential libsqlite3-dev luarocks
  sudo luarocks --lua-version=5.1 install lsqlite3
  ```
- `Permission denied` in WSL:
  run `chmod +x scripts/bootstrap-luvit.sh scripts/build-binary.sh`.
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
