from typing import Any, Literal

from pydantic import BaseModel, Field


class HealthResponse(BaseModel):
    status: str


class TargetOut(BaseModel):
    id: str
    name: str
    publisher: str
    channel_id: str
    prompt: str
    enabled: bool
    service: str = ""


class TargetsResponse(BaseModel):
    targets: list[TargetOut]
    hint: str | None = None
    site_link: str


class BufferChannel(BaseModel):
    id: str | None = None
    name: str
    service: str


class BufferOrganization(BaseModel):
    id: str | None = None
    name: str
    channels: list[BufferChannel]


class BufferChannelsResponse(BaseModel):
    organizations: list[BufferOrganization]


class UploadResponse(BaseModel):
    url: str


class GenerateRequest(BaseModel):
    report: str = Field(min_length=1)
    target_id: str = Field(min_length=1)
    include_site_link: bool = True


class GenerateResponse(BaseModel):
    text: str
    target_id: str


class PublishRequest(BaseModel):
    target_ids: list[str] = Field(min_length=1)
    text: str = Field(min_length=1)
    image_urls: list[str] = Field(default_factory=list)
    mode: Literal["queue", "now"] = "queue"


class PublishItem(BaseModel):
    target_id: str
    ok: bool
    post: dict[str, Any] | None = None
    error: str | None = None
    message: str | None = None


class PublishResponse(BaseModel):
    results: list[PublishItem]
    message: str
