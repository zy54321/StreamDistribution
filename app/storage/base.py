from abc import ABC, abstractmethod


class BaseStorage(ABC):
    @abstractmethod
    def upload(self, data: bytes, ext: str, content_type: str) -> str:
        """Upload image bytes and return a public URL."""
