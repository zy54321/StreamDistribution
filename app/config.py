from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import yaml
from dotenv import load_dotenv

ROOT_DIR = Path(__file__).resolve().parent.parent
CONFIG_DIR = ROOT_DIR / "config"
PROMPTS_DIR = ROOT_DIR / "app" / "generator" / "prompts"
STATIC_DIR = ROOT_DIR / "static"
CHANNELS_PATH = CONFIG_DIR / "channels.yaml"

load_dotenv(ROOT_DIR / ".env")


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


class Settings:
    def __init__(self) -> None:
        self.buffer_api_key = _env("BUFFER_API_KEY")
        self.r2_access_key_id = _env("R2_ACCESS_KEY_ID")
        self.r2_secret_access_key = _env("R2_SECRET_ACCESS_KEY")
        self.r2_bucket = _env("R2_BUCKET")
        self.r2_endpoint_url = _env("R2_ENDPOINT_URL")
        self.r2_public_base_url = _env("R2_PUBLIC_BASE_URL")
        self.llm_base_url = _env("LLM_BASE_URL", "https://api.deepseek.com/v1")
        self.llm_api_key = _env("LLM_API_KEY")
        self.llm_model = _env("LLM_MODEL", "deepseek-chat")
        self.site_link = _env("SITE_LINK", "https://qingsys.com/en")

    def require(self, attr: str, env_name: str) -> str:
        value = str(getattr(self, attr, "") or "").strip()
        if not value:
            raise RuntimeError(f"缺少环境变量 {env_name}")
        return value


settings = Settings()


class ConfigError(Exception):
    """Raised when channel or prompt configuration cannot be used."""


def _as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "y", "on"}
    if isinstance(value, int):
        return value != 0
    return False


def load_channels() -> tuple[list[dict[str, Any]], str | None]:
    """Load the channel registry. A missing or invalid file does not raise."""
    if not CHANNELS_PATH.exists():
        return [], (
            "未找到 config/channels.yaml。请复制 config/channels.example.yaml "
            "为 config/channels.yaml 并填写渠道。"
        )
    try:
        raw = yaml.safe_load(CHANNELS_PATH.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        return [], f"config/channels.yaml 解析失败：{exc}"
    except OSError as exc:
        return [], f"无法读取 config/channels.yaml：{exc}"

    if not isinstance(raw, dict):
        return [], "config/channels.yaml 根节点必须是映射（包含 targets 列表）。"

    targets = raw.get("targets", [])
    if targets is None:
        targets = []
    if not isinstance(targets, list):
        return [], "config/channels.yaml 的 targets 必须是列表。"

    normalized: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, item in enumerate(targets):
        if not isinstance(item, dict):
            return [], f"targets[{index}] 必须是映射。"
        target_id = str(item.get("id") or "").strip()
        if not target_id:
            return [], f"targets[{index}] 缺少 id。"
        if target_id in seen:
            return [], f"重复的渠道 id：{target_id}"
        seen.add(target_id)
        normalized.append(
            {
                "id": target_id,
                "name": str(item.get("name") or target_id).strip() or target_id,
                "publisher": str(item.get("publisher") or "").strip(),
                "channel_id": str(item.get("channel_id") or "").strip(),
                "prompt": str(item.get("prompt") or "").strip(),
                "enabled": _as_bool(item.get("enabled", False)),
                "service": str(item.get("service") or "").strip(),
            }
        )
    return normalized, None


def enabled_targets() -> tuple[list[dict[str, Any]], str | None]:
    targets, hint = load_channels()
    if hint:
        return [], hint
    enabled = [target for target in targets if target["enabled"]]
    if not enabled:
        return [], "channels.yaml 中没有 enabled: true 的渠道。"
    return enabled, None


def get_target(target_id: str) -> dict[str, Any]:
    targets, hint = load_channels()
    if hint and not targets:
        raise ConfigError(hint)
    for target in targets:
        if target["id"] == target_id and target["enabled"]:
            return target
    raise ConfigError(f"未找到已启用的渠道：{target_id}")


def load_prompt(filename: str) -> str:
    if not filename or Path(filename).name != filename or not filename.endswith(".md"):
        raise ConfigError("prompt 必须是 prompts 目录中的 .md 文件名。")
    root = PROMPTS_DIR.resolve()
    path = (PROMPTS_DIR / filename).resolve()
    if not path.is_relative_to(root):
        raise ConfigError("prompt 路径不合法。")
    if not path.is_file():
        raise ConfigError(f"未找到 Prompt 文件：{filename}")
    return path.read_text(encoding="utf-8")
