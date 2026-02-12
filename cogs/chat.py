from __future__ import annotations

import base64
import json
import mimetypes
import re
from typing import cast

import discord
from discord.ext import commands, tasks

from config import Settings
from client import ChatMessage, ImageInput, LLMClient
from logger.chat_logger import ChatReplayLogger
from memory_store import ShortTermMemoryStore


class AIChatCog(commands.Cog):
    CLEANUP_INTERVAL_SECONDS = 60
    DEFAULT_PROMPT = "hi"
    DEFAULT_MENTION_PROMPT = "hi"
    SUPPORTED_PREFIX_COMMANDS = {"chat", "ask"}
    EVERYONE_MENTION_PATTERN = re.compile(r"@everyone", flags=re.IGNORECASE)
    HERE_MENTION_PATTERN = re.compile(r"@here", flags=re.IGNORECASE)

    def __init__(self, bot: commands.Bot, settings: Settings):
        self.bot = bot
        self.settings = settings
        self.client = LLMClient(settings=settings)
        self.chat_memory = ShortTermMemoryStore(
            db_path=settings.chat_memory_db_path,
            max_history_turns=settings.max_history,
        )
        self.ban_store = ShortTermMemoryStore(
            db_path=settings.ban_db_path,
            max_history_turns=settings.max_history,
        )
        self.callnames_store = ShortTermMemoryStore(
            db_path=settings.callnames_db_path,
            max_history_turns=settings.max_history,
        )
        self.replay_logger = ChatReplayLogger(settings.chat_replay_log_path)
        self.is_terminated = False
        replay_prefix = re.escape(self.settings.command_prefix)
        self.inline_replay_pattern = re.compile(
            rf"^{replay_prefix}replaymiku(\d+)$",
            flags=re.IGNORECASE,
        )

    async def cog_load(self) -> None:
        await self.chat_memory.initialize()
        await self.ban_store.initialize()
        await self.callnames_store.initialize()
        await self.replay_logger.initialize()
        if self.settings.memory_idle_ttl_seconds > 0:
            self.cleanup_inactive_memory.start()

    async def cog_unload(self) -> None:
        if self.cleanup_inactive_memory.is_running():
            self.cleanup_inactive_memory.cancel()
        await self.chat_memory.close()
        await self.ban_store.close()
        await self.callnames_store.close()
        await self.client.aclose()

    @tasks.loop(seconds=CLEANUP_INTERVAL_SECONDS)
    async def cleanup_inactive_memory(self) -> None:
        try:
            await self.chat_memory.prune_inactive_channels(
                self.settings.memory_idle_ttl_seconds
            )
        except Exception as exc:
            print(f"[memory-cleanup] error: {exc}")

    @cleanup_inactive_memory.before_loop
    async def before_cleanup_inactive_memory(self) -> None:
        await self.bot.wait_until_ready()

    async def _load_history_messages(self, channel_id: int) -> list[ChatMessage]:
        history_raw = await self.chat_memory.get_history(channel_id)
        return [
            {"role": msg["role"], "content": msg["content"]} for msg in history_raw
        ]

    def _normalize_prompt(self, prompt: str, fallback: str) -> str:
        return prompt.strip() or fallback

    def _memory_user_entry(self, prompt: str, image_count: int) -> str:
        if image_count <= 0:
            return prompt
        return f"{prompt}\n[attached_images={image_count}]"

    async def _generate_reply(
        self,
        channel_id: int,
        user_prompt: str,
        images: list[ImageInput] | None = None,
        fallback_prompt: str | None = None,
        guild_id: int | None = None,
        user_id: int | None = None,
    ) -> str:
        normalized_prompt = self._normalize_prompt(
            user_prompt,
            fallback_prompt or self.DEFAULT_PROMPT,
        )
        prompt_for_llm = await self._apply_call_preferences_to_prompt(
            normalized_prompt,
            guild_id=guild_id,
            user_id=user_id,
        )
        image_inputs = images or []
        history = await self._load_history_messages(channel_id)
        user_message: ChatMessage = {"role": "user", "content": prompt_for_llm}
        if image_inputs:
            user_message["images"] = image_inputs

        llm_messages: list[ChatMessage] = [
            *history,
            user_message,
        ]

        raw_reply = await self.client.generate(llm_messages)
        reply = self._normalize_model_reply(raw_reply)

        await self.chat_memory.append_message(
            channel_id,
            "user",
            self._memory_user_entry(normalized_prompt, len(image_inputs)),
        )
        await self.chat_memory.append_message(channel_id, "assistant", reply)
        return reply

    async def _apply_call_preferences_to_prompt(
        self,
        prompt: str,
        guild_id: int | None,
        user_id: int | None,
    ) -> str:
        if guild_id is None or user_id is None:
            return prompt

        user_calls_miku, miku_calls_user = await self.callnames_store.get_user_call_preferences(
            guild_id=guild_id,
            user_id=user_id,
        )
        if not user_calls_miku and not miku_calls_user:
            return prompt

        parts = ["[xung_ho_context]"]
        if user_calls_miku:
            parts.append(f"user goi Miku la: {user_calls_miku}")
        if miku_calls_user:
            parts.append(f"Miku goi user la: {miku_calls_user}")
        parts.append("[noi_dung]")
        parts.append(prompt)
        return "\n".join(parts)

    async def _extract_images_from_message(
        self,
        message: discord.Message | None,
    ) -> list[ImageInput]:
        if message is None:
            return []

        images: list[ImageInput] = []
        for attachment in message.attachments:
            mime_type = (attachment.content_type or "").lower()
            if not mime_type:
                guessed_mime, _ = mimetypes.guess_type(attachment.filename)
                mime_type = (guessed_mime or "").lower()
            if not mime_type.startswith("image/"):
                continue
            if attachment.size > self.settings.image_max_bytes:
                raise RuntimeError(
                    f"Anh '{attachment.filename}' vuot gioi han "
                    f"{self.settings.image_max_bytes} bytes."
                )

            data = await attachment.read(use_cached=True)
            images.append(
                {
                    "mime_type": mime_type,
                    "data_b64": base64.b64encode(data).decode("ascii"),
                }
            )

        return images

    async def _run_chat_and_reply(
        self,
        target: commands.Context[commands.Bot] | discord.Message,
        channel_id: int,
        prompt: str,
        source_message: discord.Message | None,
        fallback_prompt: str,
        guild_id: int | None,
        user_id: int | None,
        user_name: str,
        user_display: str,
        trigger: str,
    ) -> None:
        effective_prompt = self._normalize_prompt(prompt, fallback_prompt)
        async with self._typing_context(target):
            try:
                images = await self._extract_images_from_message(source_message)
                reply = await self._generate_reply(
                    channel_id=channel_id,
                    user_prompt=effective_prompt,
                    images=images,
                    fallback_prompt=fallback_prompt,
                    guild_id=guild_id,
                    user_id=user_id,
                )
            except Exception as exc:
                await self._send_error(target, exc)
                return

        guild_name, channel_name = self._resolve_scope_names(target, source_message)
        await self.replay_logger.log_chat(
            guild_id=guild_id,
            guild_name=guild_name,
            channel_id=channel_id,
            channel_name=channel_name,
            user_id=user_id or 0,
            user_name=user_name,
            user_display=user_display,
            trigger=trigger,
            prompt=effective_prompt,
            reply_length=len(reply),
        )
        await self._send_long_message(target, reply)

    def _resolve_scope_names(
        self,
        target: commands.Context[commands.Bot] | discord.Message,
        source_message: discord.Message | None,
    ) -> tuple[str | None, str | None]:
        if source_message is not None:
            guild_name = source_message.guild.name if source_message.guild else None
            channel_name = getattr(source_message.channel, "name", None)
            return guild_name, channel_name

        if isinstance(target, commands.Context):
            guild_name = target.guild.name if target.guild else None
            channel_name = getattr(target.channel, "name", None)
            return guild_name, channel_name

        guild_name = target.guild.name if target.guild else None
        channel_name = getattr(target.channel, "name", None)
        return guild_name, channel_name

    async def _is_banned_user(self, guild_id: int | None, user_id: int) -> bool:
        if guild_id is None:
            return False
        return await self.ban_store.is_user_banned(guild_id, user_id)

    def _typing_context(
        self,
        target: commands.Context[commands.Bot] | discord.Message,
    ):
        if isinstance(target, commands.Context):
            return target.typing()
        return target.channel.typing()

    async def _send_error(
        self,
        target: commands.Context[commands.Bot] | discord.Message,
        exc: Exception,
    ) -> None:
        message = f"Loi khi goi AI: `{exc}`"
        if isinstance(target, commands.Context):
            await target.reply(message, mention_author=False)
            return
        await target.reply(message, mention_author=False)

    async def _is_owner(self, user: discord.abc.User) -> bool:
        return await self.bot.is_owner(user)

    def _extract_inline_replay_id(self, content: str) -> int | None:
        matched = self.inline_replay_pattern.match(content.strip())
        if not matched:
            return None
        return int(matched.group(1))

    def _extract_prefixed_command_name(self, content: str) -> str | None:
        stripped = content.strip()
        prefix = self.settings.command_prefix
        if not stripped.startswith(prefix):
            return None
        return stripped[len(prefix) :].split(maxsplit=1)[0].lower()

    async def _build_replay_payload(
        self,
        *,
        action: str,
        guild_id: int | None,
    ) -> str:
        action_value = action.strip().lower()
        if action_value == "ls":
            records = await self.replay_logger.read_recent_indexed(
                limit=30,
                guild_id=guild_id,
            )
            if not records:
                return "Chua co replay chat nao."

            lines: list[str] = ["Replay logs (moi nhat truoc):"]
            for record_id, item in records:
                ts = item.get("ts_utc", "?")
                trigger = item.get("trigger", "?")
                user_display = item.get("user_display", "unknown")
                user_id = item.get("user_id", "?")
                prompt = str(item.get("prompt", "")).replace("\n", " ").strip()
                if len(prompt) > 70:
                    prompt = prompt[:67] + "..."
                lines.append(
                    f"[{record_id}] {ts} | {user_display} ({user_id}) | {trigger} | {prompt}"
                )
            lines.append(
                f"Dung `{self.settings.command_prefix}replaymiku <id>` de xem chi tiet."
            )
            return "\n".join(lines)

        try:
            record_id = int(action_value)
        except ValueError as exc:
            raise ValueError(
                f"Dung: `{self.settings.command_prefix}replaymiku ls` hoac "
                f"`{self.settings.command_prefix}replaymiku <id>`."
            ) from exc

        item = await self.replay_logger.get_by_index(
            record_id=record_id,
            guild_id=guild_id,
        )
        if item is None:
            return f"Khong tim thay replay id `{record_id}`."

        prompt = str(item.get("prompt", "(rong)")).strip()
        lines = [
            f"Replay #{record_id}",
            f"Time: {item.get('ts_utc', '?')}",
            f"Guild: {item.get('guild_name', '?')} ({item.get('guild_id', '?')})",
            f"Channel: {item.get('channel_name', '?')} ({item.get('channel_id', '?')})",
            f"User: {item.get('user_display', '?')} ({item.get('user_id', '?')})",
            f"Trigger: {item.get('trigger', '?')}",
            f"Reply length: {item.get('reply_length', '?')}",
            "Prompt:",
            prompt,
        ]
        return "\n".join(lines)

    @commands.hybrid_command(
        name="chat",
        aliases=["ask"],
        with_app_command=True,
        description="Chat voi AI bot",
    )
    async def chat(
        self,
        ctx: commands.Context[commands.Bot],
        *,
        prompt: str | None = None,
    ) -> None:
        """Chat with the AI bot."""
        if await self._is_banned_user(
            guild_id=ctx.guild.id if ctx.guild else None,
            user_id=ctx.author.id,
        ):
            await ctx.reply(
                "Ban da bi ban khoi AI bot trong server nay.",
                mention_author=False,
            )
            return

        if self.is_terminated:
            await ctx.reply(
                "Bot dang o che do terminated. Dung `!terminated off` de mo lai.",
                mention_author=False,
            )
            return

        await self._run_chat_and_reply(
            target=ctx,
            channel_id=ctx.channel.id,
            prompt=prompt or "",
            source_message=getattr(ctx, "message", None),
            fallback_prompt=self.DEFAULT_PROMPT,
            guild_id=ctx.guild.id if ctx.guild else 0,
            user_id=ctx.author.id,
            user_name=ctx.author.name,
            user_display=ctx.author.display_name,
            trigger="command",
        )

    @commands.command(name="clearmemo", aliases=["resetchat"])
    async def clear_memo(self, ctx: commands.Context[commands.Bot]) -> None:
        await self.chat_memory.clear_channel(ctx.channel.id)
        await ctx.reply(
            "Da xoa bo nho ngan han cua channel nay.",
            mention_author=False,
        )

    @commands.command(name="terminated")
    async def terminated(
        self,
        ctx: commands.Context[commands.Bot],
        mode: str = "on",
    ) -> None:
        action = mode.strip().lower()
        if action in {"on", "1", "true"}:
            self.is_terminated = True
            await ctx.reply(
                "Da bat terminated: bot se khong tra loi chat/mention.",
                mention_author=False,
            )
            return

        if action in {"off", "0", "false"}:
            self.is_terminated = False
            await ctx.reply(
                "Da tat terminated: bot co the tra loi lai binh thuong.",
                mention_author=False,
            )
            return

        if action == "status":
            status = "ON" if self.is_terminated else "OFF"
            await ctx.reply(
                f"Terminated status: `{status}`",
                mention_author=False,
            )
            return

        await ctx.reply(
            "Dung: `!terminated on`, `!terminated off`, hoac `!terminated status`.",
            mention_author=False,
        )

    @commands.command(name="provider")
    async def provider(self, ctx: commands.Context[commands.Bot]) -> None:
        await ctx.reply(
            f"Provider hien tai: `{self.settings.provider}` | "
            f"Model: `{self.settings.gemini_model if self.settings.provider == 'gemini' else self.settings.groq_model}` | "
            f"Approval provider: `gemini` | "
            f"Approval model: `{self.settings.gemini_approval_model}` | "
            f"Chat DB: `{self.settings.chat_memory_db_path}` | "
            f"Ban DB: `{self.settings.ban_db_path}` | "
            f"Callnames DB: `{self.settings.callnames_db_path}` | "
            f"Idle TTL: `{self.settings.memory_idle_ttl_seconds}s` | "
            f"Image limit: `{self.settings.image_max_bytes}` bytes | "
            f"Terminated: `{self.is_terminated}`"
        )

    @commands.command(name="replaymiku")
    async def replay_miku(
        self,
        ctx: commands.Context[commands.Bot],
        action: str = "ls",
    ) -> None:
        if not await self._is_owner(ctx.author):
            await ctx.reply(
                "Lenh nay chi chu bot moi duoc dung.",
                mention_author=False,
            )
            return

        try:
            payload = await self._build_replay_payload(
                action=action,
                guild_id=ctx.guild.id if ctx.guild else None,
            )
        except ValueError as exc:
            await ctx.reply(str(exc), mention_author=False)
            return
        await self._send_long_message(ctx, payload)

    @commands.Cog.listener()
    async def on_message(self, message: discord.Message) -> None:
        if message.author.bot:
            return

        replay_id = self._extract_inline_replay_id(message.content)
        if replay_id is not None:
            if not await self._is_owner(message.author):
                await message.reply(
                    "Lenh nay chi chu bot moi duoc dung.",
                    mention_author=False,
                )
                return
            payload = await self._build_replay_payload(
                action=str(replay_id),
                guild_id=message.guild.id if message.guild else None,
            )
            await self._send_long_message(message, payload)
            return

        if self._looks_like_chat_command(message.content):
            return

        me = cast(discord.ClientUser | None, self.bot.user)
        if me is None:
            return

        if await self._is_banned_user(
            guild_id=message.guild.id if message.guild else None,
            user_id=message.author.id,
        ):
            return

        if self.is_terminated:
            return

        # Bot auto-reply when mentioned directly.
        if me in message.mentions:
            mention_text = message.content.replace(f"<@{me.id}>", "").replace(
                f"<@!{me.id}>", ""
            )
            await self._run_chat_and_reply(
                target=message,
                channel_id=message.channel.id,
                prompt=mention_text,
                source_message=message,
                fallback_prompt=self.DEFAULT_MENTION_PROMPT,
                guild_id=message.guild.id if message.guild else 0,
                user_id=message.author.id,
                user_name=message.author.name,
                user_display=message.author.display_name,
                trigger="mention",
            )

    def _looks_like_chat_command(self, content: str) -> bool:
        command_name = self._extract_prefixed_command_name(content)
        if command_name is None:
            return False
        return command_name in self.SUPPORTED_PREFIX_COMMANDS

    async def _send_long_message(
        self,
        target: commands.Context[commands.Bot] | discord.Message,
        text: str,
    ) -> None:
        text = self._sanitize_bot_output(text)
        max_len = 1900
        chunks = [text[i : i + max_len] for i in range(0, len(text), max_len)] or ["(khong co noi dung)"]

        for idx, chunk in enumerate(chunks):
            if isinstance(target, commands.Context):
                if idx == 0:
                    await target.reply(chunk, mention_author=False)
                else:
                    await target.send(chunk)
            else:
                if idx == 0:
                    await target.reply(chunk, mention_author=False)
                else:
                    await target.channel.send(chunk)

    def _sanitize_bot_output(self, text: str) -> str:
        text = self.EVERYONE_MENTION_PATTERN.sub("@\u200beveryone", text)
        text = self.HERE_MENTION_PATTERN.sub("@\u200bhere", text)
        return text

    def _normalize_model_reply(self, text: str) -> str:
        answer = self._extract_answer_from_structured_output(text)
        if answer is None:
            return text
        return answer

    def _extract_answer_from_structured_output(self, text: str) -> str | None:
        stripped = text.strip()
        if not stripped:
            return None

        # Accept JSON directly or wrapped in ```json ... ``` fences.
        fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", stripped, flags=re.DOTALL)
        candidate = fenced.group(1).strip() if fenced else stripped

        decoder = json.JSONDecoder()
        for idx, char in enumerate(candidate):
            if char != "{":
                continue
            try:
                data, _ = decoder.raw_decode(candidate[idx:])
            except json.JSONDecodeError:
                continue
            if not isinstance(data, dict):
                continue
            answer = data.get("answer")
            if isinstance(answer, str) and answer.strip():
                return answer.strip()

        return None


async def setup(bot: commands.Bot) -> None:
    settings = cast(Settings, getattr(bot, "settings"))
    await bot.add_cog(AIChatCog(bot, settings))
