from __future__ import annotations

import base64
import binascii
from typing import Any, Awaitable, Callable, TypedDict, cast

from google import genai
from google.genai import types as genai_types
from groq import AsyncGroq

from config import Settings


class ImageInput(TypedDict):
    mime_type: str
    data_b64: str


class ChatMessage(TypedDict, total=False):
    role: str
    content: str
    images: list[ImageInput]


class LLMClient:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.gemini_client = (
            genai.Client(api_key=settings.gemini_api_key)
            if settings.gemini_api_key
            else None
        )
        approval_key = settings.approval_gemini_api_key
        if approval_key and approval_key == settings.gemini_api_key and self.gemini_client:
            self.approval_gemini_client = self.gemini_client
        else:
            self.approval_gemini_client = (
                genai.Client(api_key=approval_key) if approval_key else None
            )
        self.groq_client = (
            AsyncGroq(api_key=settings.groq_api_key) if settings.groq_api_key else None
        )

    async def aclose(self) -> None:
        if self.groq_client and hasattr(self.groq_client, "close"):
            await self.groq_client.close()

    async def generate(self, messages: list[ChatMessage]) -> str:
        handlers: dict[str, Callable[[list[ChatMessage]], Awaitable[str]]] = {
            "gemini": self._call_gemini,
            "groq": self._call_groq,
        }
        handler = handlers.get(self.settings.provider)
        if handler is None:
            raise RuntimeError(f"Unsupported provider: {self.settings.provider}")
        return await handler(messages)

    async def approve_call_name(self, field_name: str, value: str) -> bool:
        raw = await self._approve_call_name_gemini(field_name, value)
        verdict = self._normalize_yes_no(raw)
        return verdict == "yes"

    async def _approve_call_name_gemini(self, field_name: str, value: str) -> str:
        if self.approval_gemini_client is None:
            raise RuntimeError(
                "Missing APPROVAL_GEMINI_API_KEY (or GEMINI_API_KEY fallback)"
            )

        response = await self.approval_gemini_client.aio.models.generate_content(
            model=self.settings.gemini_approval_model,
            contents=[
                genai_types.Content(
                    role="user",
                    parts=[
                        genai_types.Part.from_text(
                            text=f"Call-name field: {field_name}\nContent: {value}"
                        )
                    ],
                )
            ],
            config=genai_types.GenerateContentConfig(
                temperature=0,
                system_instruction=self._approval_system_instruction(),
            ),
        )
        return self._extract_gemini_text(response, context="Gemini approval")

    async def _call_gemini(self, messages: list[ChatMessage]) -> str:
        if self.gemini_client is None:
            raise RuntimeError("Missing GEMINI_API_KEY")
        response = await self.gemini_client.aio.models.generate_content(
            model=self.settings.gemini_model,
            contents=self._build_gemini_contents(messages),
            config=genai_types.GenerateContentConfig(
                temperature=self.settings.temperature,
                system_instruction=self.settings.system_prompt,
            ),
        )
        return self._extract_gemini_text(response, context="Gemini")

    async def _call_groq(self, messages: list[ChatMessage]) -> str:
        if self.groq_client is None:
            raise RuntimeError("Missing GROQ_API_KEY")
        chat_completion = await self.groq_client.chat.completions.create(
            model=self.settings.groq_model,
            messages=self._build_groq_messages(messages),
            temperature=self.settings.temperature,
        )
        message = chat_completion.choices[0].message
        content = message.content
        if isinstance(content, str) and content.strip():
            return content.strip()
        raise RuntimeError("Groq returned an empty response.")

    def _build_gemini_contents(
        self,
        messages: list[ChatMessage],
    ) -> list[genai_types.Content]:
        contents: list[genai_types.Content] = []
        for msg in messages:
            role = "model" if msg["role"] == "assistant" else "user"
            parts = self._build_gemini_parts(msg)
            if parts:
                contents.append(genai_types.Content(role=role, parts=parts))
        return contents

    def _build_groq_messages(
        self,
        messages: list[ChatMessage],
    ) -> list[dict[str, Any]]:
        groq_messages: list[dict[str, Any]] = [
            {"role": "system", "content": self.settings.system_prompt}
        ]
        for msg in messages:
            text = msg.get("content", "").strip()
            images = msg.get("images", [])
            if images:
                parts: list[dict[str, Any]] = []
                if text:
                    parts.append({"type": "text", "text": text})
                for image in images:
                    data_url = f"data:{image['mime_type']};base64,{image['data_b64']}"
                    parts.append({"type": "image_url", "image_url": {"url": data_url}})
                groq_messages.append({"role": msg["role"], "content": parts})
            elif text:
                groq_messages.append({"role": msg["role"], "content": text})
        return groq_messages

    def _build_gemini_parts(self, msg: ChatMessage) -> list[genai_types.Part]:
        parts: list[genai_types.Part] = []
        text = msg.get("content", "").strip()
        if text:
            parts.append(genai_types.Part.from_text(text=text))

        for image in msg.get("images", []):
            parts.append(self._image_part_from_b64(image))
        return parts

    def _image_part_from_b64(
        self,
        image: ImageInput,
    ) -> genai_types.Part:
        try:
            raw_bytes = base64.b64decode(image["data_b64"], validate=True)
        except (binascii.Error, ValueError) as exc:
            raise RuntimeError("Invalid image base64 input.") from exc
        return genai_types.Part.from_bytes(
            data=raw_bytes,
            mime_type=image["mime_type"],
        )

    def _extract_gemini_text(
        self,
        response: Any,
        *,
        context: str,
    ) -> str:
        direct_text = cast(str | None, getattr(response, "text", None))
        if direct_text and direct_text.strip():
            return direct_text.strip()

        candidates = cast(list[Any], getattr(response, "candidates", []) or [])
        for candidate in candidates:
            content = getattr(candidate, "content", None)
            if content is None:
                continue
            parts = cast(list[Any], getattr(content, "parts", []) or [])
            text_parts = [
                str(part.text).strip()
                for part in parts
                if getattr(part, "text", None)
                and str(part.text).strip()
            ]
            if text_parts:
                return "\n".join(text_parts)
        raise RuntimeError(f"{context} returned an empty response.")

    def _normalize_yes_no(self, value: str) -> str | None:
        cleaned = value.strip().lower().strip("`'\".!?[](){} ")
        if cleaned in {"yes", "y"}:
            return "yes"
        if cleaned in {"no", "n"}:
            return "no"
        return None

    def _approval_system_instruction(self) -> str:
        return (
            "You are a moderator for Discord call-names. "
            "Reply with exactly one word: 'yes' or 'no'. "
            "Reply 'no' if the content is insulting, harassing, hateful, sexual, "
            "discriminatory, or generally not appropriate for respectful addressing."
        )
