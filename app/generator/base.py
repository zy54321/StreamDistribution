from abc import ABC, abstractmethod


class BaseGenerator(ABC):
    @abstractmethod
    def generate(self, report: str, prompt_template: str, options: dict) -> str:
        """Turn a development report into post text."""
