# Stream Distribution

无状态、单容器的内容分发中转。开发汇报在本机生成英文草稿，图片进 Cloudflare R2，文本和图片推入 Buffer 队列。没有数据库，没有登录。队列和发布记录以 Buffer 为准。

四层各自独立：`app/storage`（图床）、`app/generator`（文案）、`app/publishers`（渠道）、`static`（单页）。新增渠道时实现一个 Publisher，并在 `config/channels.yaml` 登记，不必改前端契约。

## 本地运行

```powershell
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env
copy config\channels.example.yaml config\channels.yaml
uvicorn app.main:app --host 127.0.0.1 --port 8000
```

打开 <http://127.0.0.1:8000>。

## Docker

只监听本机 `8085`，配置目录只读挂载。容器内没有 `channels.yaml` 的副本，以宿主机 `./config` 为准。

```powershell
copy .env.example .env
copy config\channels.example.yaml config\channels.yaml
docker compose up --build
```

打开 <http://127.0.0.1:8085>。修改 `.env` 后需要重建或重启容器。修改 `channels.yaml` 会在下次请求时重新读取。

## 环境变量

见 `.env.example`。

| 变量 | 用途 |
| --- | --- |
| `BUFFER_API_KEY` | Buffer GraphQL Bearer Token |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | R2 S3 凭证 |
| `R2_BUCKET` | 桶名 |
| `R2_ENDPOINT_URL` | `https://<account_id>.r2.cloudflarestorage.com` |
| `R2_PUBLIC_BASE_URL` | 公开直链前缀 |
| `LLM_BASE_URL` | OpenAI 兼容地址，DeepSeek 用 `https://api.deepseek.com/v1` |
| `LLM_API_KEY` | 模型密钥 |
| `LLM_MODEL` | 例如 `deepseek-chat` |
| `SITE_LINK` | 勾选附带链接时写入草稿的 URL，默认 `https://qingsys.com/en` |

`channels.yaml` 不存在或没有启用渠道时，进程仍会启动。`GET /api/targets` 返回空列表和说明。

## channels.yaml

```yaml
targets:
  - id: x_main
    name: X Main
    publisher: buffer
    channel_id: ""          # GET /api/buffer/channels 返回的 channel id
    prompt: x_en.md         # app/generator/prompts/ 下的文件名
    enabled: true
    service: twitter        # 可选，仅用于界面展示
```

填 `channel_id` 前，先写好 `BUFFER_API_KEY`，请求 `GET /api/buffer/channels`。返回每个 organization 下的 `id`、`name`、`service`。

`publisher` 目前只有 `buffer`。后续 Facebook Page 或 Reddit 的手动复制模式，加一个 Publisher 实现并在这里改 `publisher` 即可。

## API

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/health` | 健康检查 |
| GET | `/api/targets` | 已启用渠道；附带 `hint` 与 `site_link` |
| GET | `/api/buffer/channels` | 当前 Buffer 账号的 organization 与 channels |
| POST | `/api/upload` | 图片，png/jpg/jpeg/webp，单张 ≤ 5MB，返回 `{ "url" }` |
| POST | `/api/generate` | `{ "report", "target_id", "include_site_link" }` |
| POST | `/api/publish` | `{ "target_ids", "text", "image_urls", "mode" }`，`mode` 为 `queue`（默认，Buffer `addToQueue`）或 `now`（Buffer `shareNow`） |

发布按渠道分别返回结果。成功项含 `post.id` 与 `post.dueAt`，失败项含 `error`。无图时不会向 Buffer 传空的 `assets`。
