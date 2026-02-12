from __future__ import annotations

from typing import Any, Awaitable, Callable, TypedDict

import aiohttp

from config import Settings


class ImageInput(TypedDict):
    mime_type: str
    data_b64: str


class ChatMessage(TypedDict, total=False):
    role: str
    content: str
    images: list[ImageInput]


class LLMClient:
    REQUEST_TIMEOUT_SECONDS = 60

    def __init__(self, settings: Settings, session: aiohttp.ClientSession):
        self.settings = settings
        self.session = session

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
        handlers: dict[str, Callable[[str, str], Awaitable[str]]] = {
            "gemini": self._approve_call_name_gemini,
            "groq": self._approve_call_name_groq,
        }
        handler = handlers.get(self.settings.approval_provider)
        if handler is None:
            raise RuntimeError(
                f"Unsupported approval provider: {self.settings.approval_provider}"
            )
        raw = await handler(field_name, value)
        verdict = self._normalize_yes_no(raw)
        return verdict == "có"

    async def _approve_call_name_gemini(self, field_name: str, value: str) -> str:
        if not self.settings.gemini_api_key:
            raise RuntimeError("Missing GEMINI_API_KEY for approval model")

        endpoint = (
            "https://generativelanguage.googleapis.com/v1beta/models/"
            f"{self.settings.gemini_approval_model}:generateContent"
            f"?key={self.settings.gemini_api_key}"
        )
        payload: dict[str, Any] = {
            "contents": [
                {
                    "role": "user",
                    "parts": [
                        {
                            "text": (
                                f"Loai xung ho: {field_name}\n"
                                f"Noi dung: {value}"
                            )
                        }
                    ],
                }
            ],
            "generationConfig": {
                "temperature": 0,
            },
            "system_instruction": {
                "parts": [
                    {
                        "text": self._approval_system_instruction()
                    }
                ]
            },
        }

        status_code, data = await self._post_json(endpoint, payload=payload)
        self._raise_if_error("GeminiApproval", status_code, data)

        try:
            raw = data["candidates"][0]["content"]["parts"][0]["text"]
        except (KeyError, IndexError, TypeError) as exc:
            raise RuntimeError(f"Invalid Gemini approval response: {data}") from exc
        return raw

    async def _approve_call_name_groq(self, field_name: str, value: str) -> str:
        if not self.settings.groq_api_key:
            raise RuntimeError("Missing GROQ_API_KEY for approval provider")

        endpoint = "https://api.groq.com/openai/v1/chat/completions"
        headers = {
            "Authorization": f"Bearer {self.settings.groq_api_key}",
            "Content-Type": "application/json",
        }
        payload = {
            "model": self.settings.groq_approval_model,
            "temperature": 0,
            "messages": [
                {"role": "system", "content": self._approval_system_instruction()},
                {
                    "role": "user",
                    "content": f"Loai xung ho: {field_name}\nNoi dung: {value}",
                },
            ],
        }

        status_code, data = await self._post_json(
            endpoint,
            payload=payload,
            headers=headers,
        )
        self._raise_if_error("GroqApproval", status_code, data)
        try:
            raw = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise RuntimeError(f"Invalid Groq approval response: {data}") from exc
        return raw

    async def _call_gemini(self, messages: list[ChatMessage]) -> str:
        if not self.settings.gemini_api_key:
            raise RuntimeError("Missing GEMINI_API_KEY")

        endpoint = (
            "https://generativelanguage.googleapis.com/v1beta/models/"
            f"{self.settings.gemini_model}:generateContent"
            f"?key={self.settings.gemini_api_key}"
        )

        contents = self._build_gemini_contents(messages)

        payload: dict[str, Any] = {
            "contents": contents,
            "generationConfig": {
                "temperature": self.settings.temperature,
            },
            "system_instruction": {
                "parts": [{"text": self.settings.system_prompt}],
            },
        }

        status_code, data = await self._post_json(endpoint, payload=payload)
        self._raise_if_error("Gemini", status_code, data)

        try:
            return data["candidates"][0]["content"]["parts"][0]["text"].strip()
        except (KeyError, IndexError, TypeError) as exc:
            raise RuntimeError(f"Invalid Gemini response: {data}") from exc

    async def _call_groq(self, messages: list[ChatMessage]) -> str:
        if not self.settings.groq_api_key:
            raise RuntimeError("Missing GROQ_API_KEY")

        endpoint = "https://api.groq.com/openai/v1/chat/completions"
        headers = {
            "Authorization": f"Bearer {self.settings.groq_api_key}",
            "Content-Type": "application/json",
        }

        payload = {
            "model": self.settings.groq_model,
            "messages": self._build_groq_messages(messages),
            "temperature": self.settings.temperature,
        }

        status_code, data = await self._post_json(
            endpoint,
            payload=payload,
            headers=headers,
        )
        self._raise_if_error("Groq", status_code, data)

        try:
            return data["choices"][0]["message"]["content"].strip()
        except (KeyError, IndexError, TypeError) as exc:
            raise RuntimeError(f"Invalid Groq response: {data}") from exc

    def _build_gemini_contents(
        self,
        messages: list[ChatMessage],
    ) -> list[dict[str, Any]]:
        contents: list[dict[str, Any]] = []
        for msg in messages:
            role = "model" if msg["role"] == "assistant" else "user"
            parts = self._build_message_parts(msg)
            if parts:
                contents.append({"role": role, "parts": parts})
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

    def _build_message_parts(self, msg: ChatMessage) -> list[dict[str, Any]]:
        parts: list[dict[str, Any]] = []
        text = msg.get("content", "").strip()
        if text:
            parts.append({"text": text})

        for image in msg.get("images", []):
            parts.append(
                {
                    "inline_data": {
                        "mime_type": image["mime_type"],
                        "data": image["data_b64"],
                    }
                }
            )
        return parts

    async def _post_json(
        self,
        endpoint: str,
        payload: dict[str, Any],
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, Any]]:
        async with self.session.post(
            endpoint,
            headers=headers,
            json=payload,
            timeout=self.REQUEST_TIMEOUT_SECONDS,
        ) as resp:
            data = await resp.json(content_type=None)
            if not isinstance(data, dict):
                raise RuntimeError(f"Unexpected API response type: {type(data).__name__}")
            return resp.status, data

    def _raise_if_error(
        self,
        provider_name: str,
        status_code: int,
        data: dict[str, Any],
    ) -> None:
        if status_code < 400:
            return
        detail = data.get("error", {}).get("message", str(data))
        raise RuntimeError(f"{provider_name} API error ({status_code}): {detail}")

    def _normalize_yes_no(self, value: str) -> str | None:
        cleaned = value.strip().lower().strip("`'\".!?[](){} ")
        if cleaned in {"có", "co"}:
            return "có"
        if cleaned in {"ko", "không", "khong", "k"}:
            return "ko"
        return None

    def _approval_system_instruction(self) -> str:
        return (
            "Ban la bo kiem duyet ten xung ho trong Discord. "
            "Chi tra loi dung 1 tu: 'có' hoac 'ko'. "
            "Tra 'ko' neu noi dung tuc tiu, quay roi, cong kich, "
            "thuyet phuc thu han, tinh duc, phan biet doi xu, "
            "hoac khong phu hop de xung ho lich su."
        )
