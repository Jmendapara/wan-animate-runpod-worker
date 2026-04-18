# Wan 2.2 Animate RunPod Worker

Animate a character image with a driving video using [Wan 2.2 Animate 14B](https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled) running inside [ComfyUI](https://github.com/comfyanonymous/ComfyUI). Reference image and driving video are pulled from a Cloudflare R2 bucket, and the resulting animated MP4 (with audio muxed in) is uploaded back to R2.

## What's included

This image bakes in everything the Wan 2.2 Animate workflow needs — no cold-start downloads:

- ComfyUI + 7 pinned custom-node repos (WanVideoWrapper, WanAnimatePreprocess, VideoHelperSuite, KJNodes, Impact-Pack, ComfyUI_essentials, segment-anything-2)
- 9 model files (~35 GB): Wan 2.2 Animate 14B fp8, UMT5 text encoder, Wan 2.1 VAE, CLIP-Vision-H, two LoRAs (relight + Lightx2v), YOLO + ViTPose detection models, SAM 2.1

## Required configuration

Set these env vars on the endpoint:

| Variable | Purpose |
|---|---|
| `BUCKET_ENDPOINT_URL` | R2 endpoint, e.g. `https://<account>.r2.cloudflarestorage.com` |
| `BUCKET_ACCESS_KEY_ID` | R2 API token access key |
| `BUCKET_SECRET_ACCESS_KEY` | R2 API token secret |
| `R2_BUCKET_NAME` | Bucket the output is uploaded to |
| `R2_INPUT_BUCKET_NAME` | Optional — defaults to `R2_BUCKET_NAME` |

See the [full README on GitHub](https://github.com/Jmendapara/wan-animate-runpod-worker) for additional tunables.

## Input

```json
{
  "input": {
    "workflow": { /* full ComfyUI workflow JSON (API format) */ },
    "r2_inputs": [
      { "node_id": "57", "input_field": "image", "r2_key": "refs/character.png" },
      { "node_id": "63", "input_field": "video", "r2_key": "drives/dance.mp4" }
    ]
  }
}
```

- `workflow` — required. Export from ComfyUI via **Workflow → Save (API Format)**.
- `r2_inputs` — optional array. Each entry downloads the R2 object at `r2_key` into `/comfyui/input/` and overwrites `workflow[node_id].inputs[input_field]` with the downloaded filename.

## Output

```json
{
  "videos": [
    {
      "filename": "Wanimate_00001-audio.mp4",
      "type": "s3_url",
      "data": "https://<account>.r2.cloudflarestorage.com/<job_id>/.../Wanimate_00001-audio.mp4"
    }
  ]
}
```

Only the `-audio.mp4` (the final with audio muxed in) is surfaced. The silent `.mp4` and `.png` thumbnail that `VHS_VideoCombine` always writes alongside it are filtered out.

## Recommended GPU

**H100 80 GB** or **A100 80 GB**. 14s at 720×1280 with the workflow's default `blocks_to_swap=25` fits comfortably in 80 GB VRAM; smaller cards may OOM.

## More info

Full docs, Hetzner build instructions, and the source: https://github.com/Jmendapara/wan-animate-runpod-worker
