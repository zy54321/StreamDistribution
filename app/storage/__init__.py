"""Image storage backends."""

from app.storage.r2 import R2Storage


def get_storage() -> R2Storage:
    return R2Storage()
