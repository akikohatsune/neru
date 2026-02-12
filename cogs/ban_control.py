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

    def _can_manage(self, ctx: commands.Context[commands.Bot]) -> bool:
        if ctx.guild is None:
            return False
        author = ctx.author
        if not isinstance(author, discord.Member):
            return False
        perms = author.guild_permissions
        return perms.administrator or perms.manage_guild

    async def _ensure_manage_permission(
        self,
        ctx: commands.Context[commands.Bot],
    ) -> bool:
        if ctx.guild is None:
            await ctx.reply("Lenh nay chi dung duoc trong server.", mention_author=False)
            return False

        if self._can_manage(ctx):
            return True

        await ctx.reply("Ban khong co quyen dung lenh nay.", mention_author=False)
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
        if not await self._ensure_manage_permission(ctx):
            return

        if member.bot:
            await ctx.reply("Khong the ban tai khoan bot.", mention_author=False)
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
                f"Da ban {member.mention} khoi AI bot.",
                mention_author=False,
            )
            return

        await ctx.reply(
            f"Da cap nhat ban cho {member.mention}.",
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
        if not await self._ensure_manage_permission(ctx):
            return

        guild = cast(discord.Guild, ctx.guild)
        removed = await self.store.unban_user(guild.id, member.id)
        if removed:
            await ctx.reply(
                f"Da go ban {member.mention} khoi AI bot.",
                mention_author=False,
            )
            return

        await ctx.reply(
            f"{member.mention} hien khong nam trong danh sach ban.",
            mention_author=False,
        )


async def setup(bot: commands.Bot) -> None:
    settings = cast(Settings, getattr(bot, "settings"))
    await bot.add_cog(BanControlCog(bot, settings))
