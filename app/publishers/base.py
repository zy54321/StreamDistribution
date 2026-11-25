from abc import ABC, abstractmethod


class BasePublisher(ABC):
    @abstractmethod
    def publish(
        self,
        channel_id: str,
        text: str,
        image_urls: list[str],
        mode: str,
        service: str = "",
    ) -> dict:
        """Queue or share a post. mode is "queue" or "now". service selects channel metadata."""
