from __future__ import annotations

import httpx

from app.config import settings
from app.generator.base import BaseGenerator


class GeneratorError(RuntimeError):
    """Raised when the language model request fails."""


class OpenAICompatGenerator(BaseGenerator):
    def generate(self, report: str, prompt_template: str, options: dict) -> str:
        api_key = settings.require("llm_api_key", "LLM_API_KEY")
        url = _chat_url(settings.llm_base_url or "https://api.deepseek.com/v1")
        payload = {
            "model": settings.llm_model or "deepseek-chat",
            "temperature": 0.4,
            "messages": [
                {"role": "system", "content": prompt_template},
                {"role": "user", "content": _build_user_message(report, options)},
            ],
        }
        try:
            response = httpx.post(
                url,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json=payload,
                timeout=60.0,
            )
        except httpx.HTTPError as exc:
            raise GeneratorError(f"LLM 请求失败：{exc}") from exc

        if response.status_code >= 400:
            raise GeneratorError(
                f"LLM 返回 {response.status_code}：{_snippet(response.text)}"
            )
        try:
            body = response.json()
            text = body["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError, ValueError) as exc:
            raise GeneratorError(f"LLM 响应无法解析：{_snippet(response.text)}") from exc
        if not isinstance(text, str) or not text.strip():
            raise GeneratorError("LLM 返回了空文本")
        return text.strip()


def _chat_url(base: str) -> str:
    base = base.rstrip("/")
    if base.endswith("/chat/completions"):
        return base
    if base.endswith("/v1"):
        return f"{base}/chat/completions"
    return f"{base}/v1/chat/completions"


def _build_user_message(report: str, options: dict) -> str:
    lines = [
        "Translate the draft below into an English X post.",
        "Mirror its line breaks. A single newline in the draft stays a single newline.",
        "",
        "Draft:",
        report.strip(),
    ]
    if options.get("include_site_link"):
        link = str(options.get("site_link") or "").strip()
        if link:
            lines.extend(
                [
                    "",
                    "After the post, add one blank line and then this URL alone, "
                    "with no call to action: " + link,
                ]
            )
        else:
            lines.extend(["", "Do not invent a website URL."])
    else:
        lines.extend(["", "Do not include any website URL."])
    return "\n".join(lines)


def _snippet(text: str, limit: int = 400) -> str:
    return " ".join(text.split())[:limit]
