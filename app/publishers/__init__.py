"""Channel publishers. Add a module and register it in get_publisher to extend."""

from app.publishers.base import BasePublisher
from app.publishers.buffer_graphql import BufferGraphQLPublisher


def get_publisher(name: str) -> BasePublisher:
    key = (name or "").strip().lower()
    if key == "buffer":
        return BufferGraphQLPublisher()
    raise ValueError(f"未知 publisher：{name}")
