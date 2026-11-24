from __future__ import annotations

import uuid
from datetime import datetime, timezone

import boto3
from botocore.config import Config

from app.config import settings
from app.storage.base import BaseStorage

_ALLOWED_EXT = {"png", "jpg", "jpeg", "webp"}


class StorageError(RuntimeError):
    """Raised when an object cannot be stored."""


class R2Storage(BaseStorage):
    def __init__(self) -> None:
        self._bucket = settings.require("r2_bucket", "R2_BUCKET")
        self._public_base = settings.require("r2_public_base_url", "R2_PUBLIC_BASE_URL")
        self._client = boto3.client(
            "s3",
            endpoint_url=settings.require("r2_endpoint_url", "R2_ENDPOINT_URL"),
            aws_access_key_id=settings.require("r2_access_key_id", "R2_ACCESS_KEY_ID"),
            aws_secret_access_key=settings.require(
                "r2_secret_access_key", "R2_SECRET_ACCESS_KEY"
            ),
            region_name="auto",
            config=Config(signature_version="s3v4"),
        )

    def upload(self, data: bytes, ext: str, content_type: str) -> str:
        clean_ext = ext.lower().lstrip(".")
        if clean_ext not in _ALLOWED_EXT:
            raise StorageError(f"不支持的扩展名：{ext}")
        now = datetime.now(timezone.utc)
        key = f"publisher/{now:%Y}/{now:%m}/{uuid.uuid4().hex}.{clean_ext}"
        try:
            self._client.put_object(
                Bucket=self._bucket,
                Key=key,
                Body=data,
                ContentType=content_type,
            )
        except Exception as exc:
            raise StorageError(f"R2 上传失败：{exc}") from exc
        return f"{self._public_base.rstrip('/')}/{key}"
