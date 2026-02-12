from __future__ import annotations

from typing import Awaitable, Callable, cast

from discord.ext import commands

from client import LLMClient
from config import Settings
from memory_store import ShortTermMemoryStore


class CallNamesCog(commands.Cog):
    MAX_CALL_NAME_LENGTH = 60

    def __init__(self, bot: commands.Bot, settings: Settings):
        self.bot = bot
        self.settings = settings
        self.client = LLMClient(settings=settings)
        self.store = ShortTermMemoryStore(
            db_path=settings.callnames_db_path,
            max_history_turns=settings.max_history,
        )

    async def cog_load(self) -> None:
        await self.store.initialize()

    async def cog_unload(self) -> None:
        await self.store.close()
        await self.client.aclose()

    def _scope_guild_id(self, ctx: commands.Context[commands.Bot]) -> int:
        return ctx.guild.id if ctx.guild else 0

    async def _approval_or_reject(
        self,
        ctx: commands.Context[commands.Bot],
        *,
        field_name: str,
        value: str,
    ) -> bool:
        try:
            approved = await self.client.approve_call_name(
                field_name=field_name,
                value=value,
            )
        except Exception as exc:
            await ctx.reply(
                f"Unable to run call-name approval right now: `{exc}`",
                mention_author=False,
            )
            return False

        if approved:
            return True

        await ctx.reply("Call-name was rejected by approval (`no`).", mention_author=False)
        return False

    def _normalize_call_name(
        self,
        raw_name: str,
    ) -> str | None:
        value = raw_name.strip()
        if not value:
            return None
        if len(value) > self.MAX_CALL_NAME_LENGTH:
            return None
        return value

    async def _set_call_name_with_approval(
        self,
        ctx: commands.Context[commands.Bot],
        *,
        raw_name: str,
        field_name: str,
        success_message: str,
        saver: Callable[[int, int, str], Awaitable[None]],
    ) -> None:
        value = self._normalize_call_name(raw_name)
        if value is None:
            if not raw_name.strip():
                await ctx.reply("Name cannot be empty.", mention_author=False)
            else:
                await ctx.reply(
                    f"Name is too long (max {self.MAX_CALL_NAME_LENGTH} characters).",
                    mention_author=False,
                )
            return

        if not await self._approval_or_reject(
            ctx,
            field_name=field_name,
            value=value,
        ):
            return

        await saver(
            self._scope_guild_id(ctx),
            ctx.author.id,
            value,
        )
        await ctx.reply(
            success_message.format(value=value),
            mention_author=False,
        )

    @commands.hybrid_command(
        name="ucallmiku",
        aliases=["callmiku"],
        with_app_command=True,
        description="Set how you call Miku",
    )
    async def set_user_calls_miku(
        self,
        ctx: commands.Context[commands.Bot],
        *,
        name: str,
    ) -> None:
        await self._set_call_name_with_approval(
            ctx,
            raw_name=name,
            field_name="user_calls_miku",
            success_message="Saved: you call Miku `{value}`.",
            saver=self.store.set_user_calls_miku,
        )

    @commands.hybrid_command(
        name="mikucallu",
        aliases=["callme"],
        with_app_command=True,
        description="Set how Miku calls you",
    )
    async def set_miku_calls_user(
        self,
        ctx: commands.Context[commands.Bot],
        *,
        name: str,
    ) -> None:
        await self._set_call_name_with_approval(
            ctx,
            raw_name=name,
            field_name="miku_calls_user",
            success_message="Saved: Miku will call you `{value}`.",
            saver=self.store.set_miku_calls_user,
        )

    @commands.hybrid_command(
        name="mikumention",
        aliases=["callprofile"],
        with_app_command=True,
        description="Show your call-name profile with Miku",
    )
    async def show_call_profile(self, ctx: commands.Context[commands.Bot]) -> None:
        user_calls_miku, miku_calls_user = await self.store.get_user_call_preferences(
            guild_id=self._scope_guild_id(ctx),
            user_id=ctx.author.id,
        )
        await ctx.reply(
            "Current call profile | "
            f"You call Miku: `{user_calls_miku or 'Miku'}` | "
            f"Miku calls you: `{miku_calls_user or ctx.author.display_name}`",
            mention_author=False,
        )


async def setup(bot: commands.Bot) -> None:
    settings = cast(Settings, getattr(bot, "settings"))
    await bot.add_cog(CallNamesCog(bot, settings))
