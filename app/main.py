from __future__ import annotations

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from app.config import STATIC_DIR, ConfigError, enabled_targets, get_target, load_prompt, settings
from app.generator import get_generator
from app.generator.openai_compat import GeneratorError
from app.publishers import get_publisher
from app.publishers.buffer_graphql import BufferError, BufferGraphQLPublisher
from app.schemas import (
    BufferChannelsResponse,
    GenerateRequest,
    GenerateResponse,
    HealthResponse,
    PublishItem,
    PublishRequest,
    PublishResponse,
    TargetsResponse,
    UploadResponse,
)
from app.storage import get_storage
from app.storage.r2 import StorageError

MAX_IMAGE_BYTES = 5 * 1024 * 1024
ALLOWED_TYPES = {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/jpg": "jpg",
    "image/webp": "webp",
}

app = FastAPI(title="Stream Distribution", version="1.0.0")
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/")
def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(status="ok")


@app.get("/api/targets", response_model=TargetsResponse)
def targets() -> TargetsResponse:
    items, hint = enabled_targets()
    return TargetsResponse(
        targets=items,
        hint=hint,
        site_link=settings.site_link or "https://qingsys.com/en",
    )


@app.get("/api/buffer/channels", response_model=BufferChannelsResponse)
def buffer_channels() -> BufferChannelsResponse:
    try:
        organizations = BufferGraphQLPublisher().list_organizations()
    except RuntimeError as exc:
        status = 503 if str(exc).startswith("缺少环境变量") else 502
        raise HTTPException(status_code=status, detail=str(exc)) from exc
    return BufferChannelsResponse(organizations=organizations)


@app.post("/api/upload", response_model=UploadResponse)
async def upload(file: UploadFile = File(...)) -> UploadResponse:
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="空文件")
    if len(data) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=400, detail="单张图片不能超过 5MB")

    identified = _identify_image(data, file.content_type or "")
    if identified is None:
        raise HTTPException(status_code=400, detail="仅支持 png、jpg、jpeg、webp")
    ext, content_type = identified

    try:
        url = get_storage().upload(data, ext, content_type)
    except StorageError as exc:
        status = 503 if "缺少环境变量" in str(exc) else 502
        raise HTTPException(status_code=status, detail=str(exc)) from exc
    except RuntimeError as exc:
        status = 503 if str(exc).startswith("缺少环境变量") else 502
        raise HTTPException(status_code=status, detail=str(exc)) from exc
    return UploadResponse(url=url)


@app.post("/api/generate", response_model=GenerateResponse)
def generate(body: GenerateRequest) -> GenerateResponse:
    report = body.report.strip()
    if not report:
        raise HTTPException(status_code=400, detail="开发汇报不能为空")
    try:
        target = get_target(body.target_id)
        if not target["prompt"]:
            raise ConfigError(f"渠道 {target['id']} 未配置 prompt")
        template = load_prompt(target["prompt"])
        text = get_generator().generate(
            report,
            template,
            {
                "include_site_link": body.include_site_link,
                "site_link": settings.site_link or "https://qingsys.com/en",
                "target_id": target["id"],
                "target_name": target["name"],
            },
        )
    except ConfigError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except GeneratorError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except RuntimeError as exc:
        status = 503 if str(exc).startswith("缺少环境变量") else 502
        raise HTTPException(status_code=status, detail=str(exc)) from exc
    return GenerateResponse(text=text, target_id=body.target_id)


@app.post("/api/publish", response_model=PublishResponse)
def publish(body: PublishRequest) -> PublishResponse:
    text = body.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="推文不能为空")

    notice = "已立即发送" if body.mode == "now" else "已推入队列"
    results: list[PublishItem] = []
    for target_id in body.target_ids:
        target_id = target_id.strip()
        if not target_id:
            results.append(PublishItem(target_id=target_id, ok=False, error="渠道 id 为空"))
            continue
        try:
            target = get_target(target_id)
            if not target["publisher"]:
                raise ConfigError(f"渠道 {target_id} 未配置 publisher")
            if not target["channel_id"]:
                raise ConfigError(f"渠道 {target_id} 未配置 channel_id")
            publisher = get_publisher(target["publisher"])
            post = publisher.publish(
                target["channel_id"],
                text,
                [url for url in body.image_urls if url.strip()],
                body.mode,
            )
            results.append(PublishItem(target_id=target_id, ok=True, post=post, message=notice))
        except (ConfigError, BufferError, StorageError, ValueError, RuntimeError) as exc:
            results.append(PublishItem(target_id=target_id, ok=False, error=str(exc)))
    return PublishResponse(results=results, message=notice)


def _identify_image(data: bytes, content_type: str) -> tuple[str, str] | None:
    declared = content_type.split(";")[0].strip().lower()
    sniffed = _sniff_image(data)
    if declared in ALLOWED_TYPES:
        ext = ALLOWED_TYPES[declared]
        if sniffed is None or sniffed[0] != ext:
            return None
        return ext, "image/jpeg" if ext == "jpg" else declared
    if declared in {"", "application/octet-stream"} and sniffed is not None:
        return sniffed
    return None


def _sniff_image(data: bytes) -> tuple[str, str] | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png", "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpg", "image/jpeg"
    if len(data) >= 12 and data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "webp", "image/webp"
    return None
