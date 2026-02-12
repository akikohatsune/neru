from __future__ import annotations

from typing import cast

import discord
from discord.ext import commands

from config import Settings
from memory_store import ShortTermMemoryStore


class BanControlCog(commands.Cog):
    def __init__(self, bot: commands.Bot, settings: Settings):
        self.bot = bot
        self.settings = settings
        self.store = ShortTermMemoryStore(
            db_path=settings.ban_db_path,
            max_history_turns=settings.max_history,
        )

    async def cog_load(self) -> None:
        await self.store.initialize()

    async def cog_unload(self) -> None:
        await self.store.close()

    async def _ensure_owner_permission(
        self,
        ctx: commands.Context[commands.Bot],
    ) -> bool:
        if ctx.guild is None:
            await ctx.reply("This command can only be used in a server.", mention_author=False)
            return False

        if await self.bot.is_owner(ctx.author):
            return True

        await ctx.reply("Only the bot owner can use this command.", mention_author=False)
        return False

    @commands.hybrid_command(
        name="ban",
        with_app_command=True,
        description="Ban a user from using the AI bot",
    )
    async def ban_user(
        self,
        ctx: commands.Context[commands.Bot],
        member: discord.Member,
        *,
        reason: str | None = None,
    ) -> None:
        if not await self._ensure_owner_permission(ctx):
            return

        if member.bot:
            await ctx.reply("You cannot ban a bot account.", mention_author=False)
            return

        guild = cast(discord.Guild, ctx.guild)
        created = await self.store.ban_user(
            guild_id=guild.id,
            user_id=member.id,
            banned_by=ctx.author.id,
            reason=(reason or "").strip() or None,
        )

        if created:
            await ctx.reply(
                f"Banned {member.mention} from using the AI bot.",
                mention_author=False,
            )
            return

        await ctx.reply(
            f"Updated ban entry for {member.mention}.",
            mention_author=False,
        )

    @commands.hybrid_command(
        name="removeban",
        with_app_command=True,
        description="Remove AI-bot ban from a user",
    )
    async def remove_ban(
        self,
        ctx: commands.Context[commands.Bot],
        member: discord.Member,
    ) -> None:
        if not await self._ensure_owner_permission(ctx):
            return

        guild = cast(discord.Guild, ctx.guild)
        removed = await self.store.unban_user(guild.id, member.id)
        if removed:
            await ctx.reply(
                f"Removed AI-bot ban for {member.mention}.",
                mention_author=False,
            )
            return

        await ctx.reply(
            f"{member.mention} is not currently in the ban list.",
            mention_author=False,
        )


async def setup(bot: commands.Bot) -> None:
    settings = cast(Settings, getattr(bot, "settings"))
    await bot.add_cog(BanControlCog(bot, settings))
