from abc import ABC, abstractmethod


class BasePublisher(ABC):
    @abstractmethod
    def publish(self, channel_id: str, text: str, image_urls: list[str], mode: str) -> dict:
        """Queue or share a post. mode is "queue" or "now". Return id and dueAt when available."""
