"""Post text generators."""

from app.generator.openai_compat import OpenAICompatGenerator


def get_generator() -> OpenAICompatGenerator:
    return OpenAICompatGenerator()
