from __future__ import annotations

from typing import Any

import httpx

from app.config import settings
from app.publishers.base import BasePublisher

BUFFER_ENDPOINT = "https://api.buffer.com"

ORG_QUERY = """
query {
  account {
    organizations {
      id
      name
    }
  }
}
""".strip()

CHANNELS_QUERY = """
query ($orgId: OrganizationId!) {
  channels(input: { organizationId: $orgId }) {
    id
    name
    service
  }
}
""".strip()

CREATE_POST_MUTATION = """
mutation CreatePost($input: CreatePostInput!) {
  createPost(input: $input) {
    ... on PostActionSuccess {
      post {
        id
        text
        dueAt
        status
      }
    }
    ... on MutationError {
      message
    }
  }
}
""".strip()


class BufferError(RuntimeError):
    """Raised when Buffer returns an error or an unusable payload."""


# CreatePostInput.mode uses these GraphQL enum values.
BUFFER_MODES = {
    "queue": "addToQueue",
    "now": "shareNow",
}


class BufferGraphQLPublisher(BasePublisher):
    def publish(self, channel_id: str, text: str, image_urls: list[str], mode: str) -> dict:
        buffer_mode = BUFFER_MODES.get(mode)
        if buffer_mode is None:
            raise BufferError(f"不支持的发布模式：{mode}")
        if not channel_id:
            raise BufferError("渠道未配置 channel_id")

        payload: dict[str, Any] = {
            "text": text,
            "channelId": channel_id,
            "schedulingType": "automatic",
            "mode": buffer_mode,
        }
        if image_urls:
            payload["assets"] = [{"image": {"url": url}} for url in image_urls]

        data = self._graphql(CREATE_POST_MUTATION, {"input": payload})
        result = data.get("createPost")
        if not isinstance(result, dict):
            raise BufferError("Buffer 返回空的 createPost")

        message = result.get("message")
        post = result.get("post")
        if message and not post:
            raise BufferError(str(message))
        if not isinstance(post, dict):
            raise BufferError(str(message) if message else "Buffer 未返回帖子")
        return {
            "id": post.get("id"),
            "text": post.get("text"),
            "dueAt": post.get("dueAt"),
            "status": post.get("status"),
        }

    def list_organizations(self) -> list[dict[str, Any]]:
        data = self._graphql(ORG_QUERY)
        account = data.get("account") or {}
        organizations = account.get("organizations") or []
        listed: list[dict[str, Any]] = []
        for org in organizations:
            if not isinstance(org, dict):
                continue
            org_id = org.get("id")
            channels_data = self._graphql(CHANNELS_QUERY, {"orgId": org_id})
            channels = channels_data.get("channels") or []
            listed.append(
                {
                    "id": org_id,
                    "name": org.get("name") or "",
                    "channels": [
                        {
                            "id": channel.get("id"),
                            "name": channel.get("name") or "",
                            "service": channel.get("service") or "",
                        }
                        for channel in channels
                        if isinstance(channel, dict)
                    ],
                }
            )
        return listed

    def _graphql(self, query: str, variables: dict[str, Any] | None = None) -> dict[str, Any]:
        api_key = settings.require("buffer_api_key", "BUFFER_API_KEY")
        body: dict[str, Any] = {"query": query}
        if variables is not None:
            body["variables"] = variables
        try:
            response = httpx.post(
                BUFFER_ENDPOINT,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json=body,
                timeout=30.0,
            )
        except httpx.HTTPError as exc:
            raise BufferError(f"Buffer 请求失败：{exc}") from exc

        try:
            payload = response.json()
        except ValueError as exc:
            raise BufferError(
                f"Buffer 返回非 JSON（HTTP {response.status_code}）：{_snippet(response.text)}"
            ) from exc

        if response.status_code >= 400 and not payload.get("errors"):
            raise BufferError(
                f"Buffer HTTP {response.status_code}：{_snippet(response.text)}"
            )

        errors = payload.get("errors")
        if errors:
            raise BufferError(_format_errors(errors))

        create_post = (payload.get("data") or {}).get("createPost") if isinstance(payload.get("data"), dict) else None
        if isinstance(create_post, dict) and create_post.get("message") and not create_post.get("post"):
            raise BufferError(str(create_post["message"]))

        data = payload.get("data")
        if not isinstance(data, dict):
            raise BufferError("Buffer 响应缺少 data")
        return data


def _format_errors(errors: Any) -> str:
    if isinstance(errors, list):
        messages = [
            str(item.get("message") if isinstance(item, dict) else item) for item in errors
        ]
        text = "; ".join(message for message in messages if message)
        return text or "Buffer GraphQL 返回 errors"
    return str(errors) or "Buffer GraphQL 返回 errors"


def _snippet(text: str, limit: int = 400) -> str:
    return " ".join(text.split())[:limit]
