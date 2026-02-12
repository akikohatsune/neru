from __future__ import annotations

import asyncio
from pathlib import Path

import discord
from discord.ext import commands

from config import Settings, get_settings


class MikuAIBot(commands.Bot):
    def __init__(self, settings: Settings):
        intents = discord.Intents.default()
        intents.message_content = True

        super().__init__(
            command_prefix=settings.command_prefix,
            intents=intents,
            help_command=commands.DefaultHelpCommand(),
            allowed_mentions=discord.AllowedMentions.none(),
        )
        self.settings = settings

    async def setup_hook(self) -> None:
        cogs_dir = Path(__file__).parent / "cogs"
        for file in sorted(cogs_dir.glob("*.py")):
            if file.name.startswith("_"):
                continue
            await self.load_extension(f"cogs.{file.stem}")
        synced = await self.tree.sync()
        print(f"Synced {len(synced)} slash command(s).")

    async def on_ready(self) -> None:
        user = self.user
        user_id = user.id if user else "unknown"
        print(f"Logged in as {user} (ID: {user_id})")
        print(f"Provider: {self.settings.provider}")
        print("Approval provider: gemini (fixed)")
        print(f"Approval model: {self.settings.gemini_approval_model}")
        print(f"System rules JSON: {self.settings.system_rules_json}")
        print(f"Chat replay log: {self.settings.chat_replay_log_path}")
        print(f"Chat memory DB: {self.settings.chat_memory_db_path}")
        print(f"Ban DB: {self.settings.ban_db_path}")
        print(f"Callnames DB: {self.settings.callnames_db_path}")
        print(f"Memory idle TTL: {self.settings.memory_idle_ttl_seconds}s")
        print(f"Image max bytes: {self.settings.image_max_bytes}")


async def main() -> None:
    settings = get_settings()
    bot = MikuAIBot(settings)
    await bot.start(settings.discord_token)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
