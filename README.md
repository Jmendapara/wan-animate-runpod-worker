# wan-animate-runpod-worker

A [RunPod serverless](https://www.runpod.io/serverless-gpu) worker that runs the **Wan 2.2 Animate** ComfyUI workflow. Point it at a reference image and a driving video stored in a Cloudflare R2 bucket; it returns an animated MP4 with the source audio muxed in, uploaded back to R2.

Based on [`ltx-video-runpod-worker`](https://github.com/Jmendapara/ltx-video-runpod-worker). The handler is workflow-agnostic — you send the full ComfyUI workflow JSON per request along with an `r2_inputs` map telling the worker which node inputs to pull from R2 before executing.

<!-- toc -->

- [How it works](#how-it-works)
- [API](#api)
  - [Input](#input)
  - [Output](#output)
  - [Errors](#errors)
  - [Crafting the workflow JSON](#crafting-the-workflow-json)
- [Quickstart](#quickstart)
- [Building the Docker image](#building-the-docker-image)
  - [One-liner on a fresh Hetzner box](#one-liner-on-a-fresh-hetzner-box)
  - [Manual `docker buildx`](#manual-docker-buildx)
  - [GitHub Actions](#github-actions)
  - [Recommended Hetzner spec](#recommended-hetzner-spec)
- [Deploying to RunPod](#deploying-to-runpod)
- [Local development](#local-development)
- [Custom nodes and models baked into the image](#custom-nodes-and-models-baked-into-the-image)
- [Environment variables](#environment-variables)
- [Troubleshooting](#troubleshooting)

<!-- tocstop -->

## How it works

1. Container boots and `start.sh` launches ComfyUI in a restart loop (auto-recovers from crashes).
2. The handler receives a job, downloads each `r2_inputs` entry from R2 into `/comfyui/input/`, and rewrites the workflow JSON to point at the local filenames.
3. It submits the workflow to ComfyUI via `POST /prompt`, subscribes to `/ws` for execution progress, and waits for completion.
4. On success, it reads the output list from `/history`, fetches the `*-audio.mp4` file (the only one surfaced — `VHS_VideoCombine` also writes a silent `.mp4` and a `.png` thumbnail that we filter out), and uploads it to R2 via `rp_upload.upload_image()`.
5. The response contains the R2 URL.

All 7 custom-node repos and all 9 model files the workflow needs are baked into the Docker image at build time. No cold-start installation, no network calls during execution except to ComfyUI and R2.

## API

### Input

```json
{
  "input": {
    "workflow": { /* full ComfyUI workflow JSON (API format) */ },
    "r2_inputs": [
      { "node_id": "57", "input_field": "image", "r2_key": "refs/character.png" },
      { "node_id": "63", "input_field": "video", "r2_key": "drives/dance.mp4" }
    ],
    "comfy_org_api_key": "optional-per-request-key"
  }
}
```

| Field | Required | Notes |
|---|---|---|
| `workflow` | yes | Complete ComfyUI workflow, exported via **Workflow → Save (API Format)** in the UI |
| `r2_inputs` | no | Array of R2 objects to download into `/comfyui/input/` and wire into the workflow. Each entry needs `node_id`, `input_field`, and `r2_key`. `node_id` and `input_field` must match the workflow's structure exactly |
| `comfy_org_api_key` | no | For [Comfy.org API Nodes](https://docs.comfy.org/tutorials/api-nodes/overview). Overrides the `COMFY_ORG_API_KEY` env var |

### Output

```json
{
  "videos": [
    {
      "filename": "Wanimate_00001-audio.mp4",
      "type": "s3_url",
      "data": "https://<account>.r2.cloudflarestorage.com/<job_id>/1706212345-Wanimate_00001-audio.mp4"
    }
  ]
}
```

When `BUCKET_ENDPOINT_URL` is not set (local dev), the response returns `"type": "base64"` with the file contents. For production, always configure R2 — large videos will be truncated otherwise.

### Errors

Non-2xx cases return `{"error": "..."}` with a one-line reason. Common causes:

| Error | Cause |
|---|---|
| `Missing 'workflow' parameter` | Forgot the `workflow` key in input |
| `r2_inputs[N] is missing required field 'X'` | Malformed R2 input entry |
| `r2_inputs references node_id 'X' which is not in the workflow` | Typo in `node_id`, or workflow mismatch |
| `R2 credentials not configured` | One of `BUCKET_ENDPOINT_URL`, `BUCKET_ACCESS_KEY_ID`, `BUCKET_SECRET_ACCESS_KEY` is missing |
| `ComfyUI was OOM-killed` | GPU ran out of VRAM — use a larger GPU or a more aggressive `blocks_to_swap` setting |
| `Workflow validation failed` | A node references a model that isn't installed, or a required input is missing |

### Crafting the workflow JSON

1. Load your workflow in ComfyUI.
2. Workflow → **Save (API Format)** — this writes the dict-of-nodes shape (node IDs as keys), not the visual graph.
3. Open it in a text editor. For each file-loading node you want to feed from R2 (usually `LoadImage`, `VHS_LoadVideo`), the filename will be the placeholder you used while building the graph — it gets overwritten at runtime by `r2_inputs`.
4. Put the JSON under `input.workflow` in your request body.

A ready-to-use example lives in [`test_input.json`](./test_input.json) — it's the fixed Wan 2.2 Animate workflow wrapped with a sample `r2_inputs` block.

## Quickstart

Once deployed to a RunPod endpoint with R2 configured:

```bash
curl -X POST \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  -d @test_input.json \
  https://api.runpod.ai/v2/<your-endpoint-id>/runsync
```

Response contains a signed R2 URL under `output.videos[0].data`.

## Building the Docker image

The image is ~40 GB built (ComfyUI + 7 custom-node repos + 9 model files baked in). Build on a machine with ~120 GB free disk.

### One-liner on a fresh Hetzner box

SSH in, then:

```bash
export DOCKERHUB_USERNAME="your-dockerhub-user"
export DOCKERHUB_TOKEN="your-dockerhub-pat"
export IMAGE_TAG="your-user/wan-animate-runpod-worker:latest"

curl -fsSL https://raw.githubusercontent.com/Jmendapara/wan-animate-runpod-worker/main/scripts/build-on-pod.sh | bash
```

The script installs Docker, logs into Docker Hub, clones this repo, runs `docker buildx build --target final`, and pushes the image.

**For Blackwell GPUs** (RTX PRO 6000 96 GB), override the CUDA level:

```bash
export CUDA_LEVEL=12.8
curl -fsSL https://raw.githubusercontent.com/Jmendapara/wan-animate-runpod-worker/main/scripts/build-on-pod.sh | bash
```

### Manual `docker buildx`

If the one-liner breaks or you need custom args:

```bash
# Ubuntu 24.04 fresh box
curl -fsSL https://get.docker.com | sh
docker buildx create --use --name wan-builder

# Log into Docker Hub
echo "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin

# Clone and build
git clone https://github.com/Jmendapara/wan-animate-runpod-worker
cd wan-animate-runpod-worker

docker buildx build \
  --platform linux/amd64 \
  --target final \
  --build-arg COMFYUI_VERSION=latest \
  --build-arg BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04 \
  --build-arg CUDA_VERSION_FOR_COMFY=12.6 \
  --build-arg ENABLE_PYTORCH_UPGRADE=true \
  --build-arg PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu126 \
  --tag your-user/wan-animate-runpod-worker:latest \
  --push \
  .
```

### GitHub Actions

Two workflows are provided:

- **`.github/workflows/build-and-push.yml`** — manual dispatch, pick `wan-animate` or `wan-animate-blackwell`, tag the output. Good for on-demand builds.
- **`.github/workflows/release.yml`** — runs on every push to `main`, uses semantic-release to tag new versions, then builds & pushes via `docker/bake-action`.

Required repo secrets / vars:

| Name | Type | Notes |
|---|---|---|
| `DOCKERHUB_USERNAME` | secret | Docker Hub user |
| `DOCKERHUB_TOKEN` | secret | Docker Hub [access token](https://hub.docker.com/settings/security) |
| `GH_PAT` | secret | GitHub PAT with repo access, used by semantic-release to push tags |
| `DOCKERHUB_REPO` | variable | Docker Hub namespace (e.g. `jmendapara`) |
| `DOCKERHUB_IMG` | variable | Image name (e.g. `wan-animate-runpod-worker`) |

### Recommended Hetzner spec

- **CPX41** (8 vCPU, 16 GB RAM, 240 GB disk) or larger. Final image is ~40 GB; with build cache, disk usage reaches ~80 GB during the build.
- Fast network matters — the build pulls ~35 GB of model weights from Hugging Face.
- No GPU needed for the build itself.

Tear down the box after pushing to avoid lingering charges.

## Deploying to RunPod

1. Create an endpoint at https://www.runpod.io/console/serverless.
2. Container image: `your-user/wan-animate-runpod-worker:latest`.
3. GPU: **H100 80 GB** or **A100 80 GB**. 14 seconds of Wan Animate at 720×1280 needs the headroom; the workflow's `blocks_to_swap=25` helps but OOM is still possible on smaller cards.
4. Worker settings: `Min Workers=0`, `Max Workers=1` (scale as needed).
5. Environment variables:

| Variable | Required | Notes |
|---|---|---|
| `BUCKET_ENDPOINT_URL` | yes | e.g. `https://<account-id>.r2.cloudflarestorage.com` |
| `BUCKET_ACCESS_KEY_ID` | yes | R2 API token access key |
| `BUCKET_SECRET_ACCESS_KEY` | yes | R2 API token secret |
| `R2_BUCKET_NAME` | yes | Bucket for output uploads |
| `R2_INPUT_BUCKET_NAME` | no | Bucket for input downloads (defaults to `R2_BUCKET_NAME`) |

**R2 setup** (if you don't have a bucket yet):

1. Cloudflare dashboard → **R2** → **Create bucket**.
2. **Manage R2 API Tokens** → **Create API token** → scope: `Object Read & Write` on the bucket.
3. Copy `Access Key ID`, `Secret Access Key`, and the `Endpoint` URL → paste into RunPod env vars.

## Local development

```bash
docker compose up --build
```

Then open:

- ComfyUI UI: http://localhost:8188
- Handler: http://localhost:8000/runsync

Example local request (base64-returning, no R2 needed):

```bash
curl -X POST -H "Content-Type: application/json" \
  -d @test_input.json \
  http://localhost:8000/runsync
```

To test R2 end-to-end locally, uncomment the R2 env vars in `docker-compose.yml` and fill in your credentials.

## Custom nodes and models baked into the image

| Custom node | Repo |
|---|---|
| Wan Video nodes (loader, sampler, decode, LoRAs, etc.) | [kijai/ComfyUI-WanVideoWrapper](https://github.com/kijai/ComfyUI-WanVideoWrapper) |
| Wan Animate preprocess (pose, face, embeds) | [kijai/ComfyUI-WanAnimatePreprocess](https://github.com/kijai/ComfyUI-WanAnimatePreprocess) |
| Video load/combine | [Kosinkadink/ComfyUI-VideoHelperSuite](https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite) |
| KJ utility nodes (resize, mask ops, constants) | [kijai/ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes) |
| Impact Pack (`ImpactInt`) | [ltdrdata/ComfyUI-Impact-Pack](https://github.com/ltdrdata/ComfyUI-Impact-Pack) |
| Comfy essentials (`SimpleMath+`) | [cubiq/ComfyUI_essentials](https://github.com/cubiq/ComfyUI_essentials) |
| SAM 2 | [kijai/ComfyUI-segment-anything-2](https://github.com/kijai/ComfyUI-segment-anything-2) |

| Model | Source |
|---|---|
| `Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors` | `Kijai/WanVideo_comfy_fp8_scaled` |
| `kj-umt5-xxl-enc-bf16.safetensors` | `Kijai/WanVideo_comfy` |
| `wan_2.1_vae.safetensors` | `Comfy-Org/Wan_2.1_ComfyUI_repackaged` |
| `clip_vision_h.safetensors` | `Comfy-Org/Wan_2.1_ComfyUI_repackaged` |
| `WanAnimate_relight_lora_fp16_resized_from_128_to_dynamic_22.safetensors` | `Kijai/WanVideo_comfy` |
| `lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors` | `Kijai/WanVideo_comfy` |
| `yolov10m.onnx` | `Wan-AI/Wan2.2-Animate-14B` |
| `vitpose-l-wholebody.onnx` | `JunkyByte/easy_ViTPose` |
| `sam2.1_hiera_base_plus.safetensors` | `Kijai/sam2-safetensors` |

All Hugging Face repos are public — no `HUGGINGFACE_ACCESS_TOKEN` required.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `BUCKET_ENDPOINT_URL` | unset | R2 endpoint; triggers R2 mode for both input and output |
| `BUCKET_ACCESS_KEY_ID` | unset | R2 access key |
| `BUCKET_SECRET_ACCESS_KEY` | unset | R2 secret |
| `R2_BUCKET_NAME` | unset | Output upload bucket |
| `R2_INPUT_BUCKET_NAME` | `$R2_BUCKET_NAME` | Input download bucket |
| `WEBSOCKET_RECONNECT_ATTEMPTS` | `5` | Retries if the WS drops mid-job |
| `WEBSOCKET_RECONNECT_DELAY_S` | `3` | Delay between retries |
| `WEBSOCKET_TRACE` | `false` | Enable low-level frame logging (noisy) |
| `REFRESH_WORKER` | `false` | Restart worker after each job |
| `COMFY_ORG_API_KEY` | unset | Default Comfy.org API key (request can override) |
| `NETWORK_VOLUME_DEBUG` | `true` | Dump network-volume diagnostics at startup |
| `COMFY_LOG_LEVEL` | `DEBUG` | ComfyUI verbosity |
| `SERVE_API_LOCALLY` | `false` | If `true`, ComfyUI binds `0.0.0.0` (for local dev) |
| `COMFY_RESTART_DELAY` | `5` | Seconds before restart after crash |
| `COMFY_MAX_RAPID_RESTARTS` | `5` | Crash limit within `COMFY_RAPID_RESTART_WINDOW` |
| `COMFY_RAPID_RESTART_WINDOW` | `60` | Time window (seconds) for counting rapid crashes |

## Troubleshooting

Issues encountered during the `setup.sh` testing session that the Dockerfile deliberately avoids, plus hints for when they leak through:

- **Custom node fails to import** — usually a `requirements.txt` install that landed in system site-packages instead of the ComfyUI venv. The Dockerfile pins every pip call to `/opt/venv/bin/pip`; if you see this after modifying the Dockerfile, verify `which pip` inside the running container points at `/opt/venv/bin/pip`.
- **`RIFEInterpolation` node missing** — the fixed Wan Animate workflow doesn't use it; `ComfyUI-Frame-Interpolation` isn't installed. If you add a RIFE step back, you'll need `cupy-cuda12x` in the venv (`/opt/venv/bin/pip install cupy-cuda12x`).
- **Port 8188 already in use** — another ComfyUI process is running. The restart loop in `start.sh` handles this for crashes; for manual intervention, `pkill -f "python.*main.py"` before the next launch.
- **Silent exit with `curl | bash`** — not relevant here (the Dockerfile doesn't pipe), but noted because it bit us during `setup.sh` testing. Subprocesses inherited stdin from the piped script and consumed the rest of the script bytes. The Dockerfile avoids this entirely.
- **`-audio.mp4` missing from output** — check the ComfyUI log; if the source video has no audio track, `VHS_VideoCombine` may produce the silent `.mp4` only, which this worker filters out. Verify with `ffprobe` on your source clip.

## License

MIT — see [LICENSE](./LICENSE).
