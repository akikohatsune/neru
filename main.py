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

    def _resolve_rpc_status(self) -> discord.Status:
        status_map = {
            "online": discord.Status.online,
            "idle": discord.Status.idle,
            "dnd": discord.Status.dnd,
            "invisible": discord.Status.invisible,
        }
        return status_map.get(self.settings.rpc_status, discord.Status.online)

    def _build_rpc_activity(self) -> discord.BaseActivity | None:
        activity_type = self.settings.rpc_activity_type
        name = self.settings.rpc_activity_name
        if activity_type == "none":
            return None
        if activity_type == "playing":
            return discord.Game(name=name)
        if activity_type == "streaming":
            return discord.Streaming(name=name, url=self.settings.rpc_activity_url or "")

        discord_activity_map = {
            "listening": discord.ActivityType.listening,
            "watching": discord.ActivityType.watching,
            "competing": discord.ActivityType.competing,
        }
        mapped = discord_activity_map.get(activity_type, discord.ActivityType.playing)
        return discord.Activity(type=mapped, name=name)

    async def _apply_rpc_presence(self) -> None:
        if not self.settings.rpc_enabled:
            print("Discord RPC presence: disabled")
            return
        status = self._resolve_rpc_status()
        activity = self._build_rpc_activity()
        await self.change_presence(status=status, activity=activity)
        activity_type = self.settings.rpc_activity_type
        activity_name = self.settings.rpc_activity_name if activity else "(none)"
        print(
            "Discord RPC presence applied: "
            f"status={self.settings.rpc_status}, "
            f"type={activity_type}, "
            f"name={activity_name}"
        )

    async def setup_hook(self) -> None:
        cogs_dir = Path(__file__).parent / "cogs"
        for file in sorted(cogs_dir.glob("*.py")):
            if file.name.startswith("_"):
                continue
            await self.load_extension(f"cogs.{file.stem}")
        synced = await self.tree.sync()
        print(f"Synced {len(synced)} slash command(s).")

    async def on_ready(self) -> None:
        await self._apply_rpc_presence()
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
        print(f"Max reply chars: {self.settings.max_reply_chars}")


async def main() -> None:
    settings = get_settings()
    bot = MikuAIBot(settings)
    await bot.start(settings.discord_token)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
