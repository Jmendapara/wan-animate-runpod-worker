#!/bin/bash
set -uo pipefail

# On unexpected non-zero exit, print the last command so the failure isn't silent.
trap 'ec=$?; [ $ec -ne 0 ] && echo "[EXIT] code=$ec last_cmd=${BASH_COMMAND}"' EXIT

SECONDS=0
COMFY_DIR="${COMFY_DIR:-/workspace/runpod-slim/ComfyUI}"
CUSTOM_NODES_DIR="${COMFY_DIR}/custom_nodes"
MODELS_DIR="${COMFY_DIR}/models"
MAX_PARALLEL=3
HAS_ARIA2=false
# RunPod slim templates ship python3 only; fall back if bare `python` is missing.
PYTHON_BIN="${PYTHON_BIN:-$(command -v python || command -v python3 || echo python3)}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }
ok()   { echo -e "${CYAN}[DONE]${NC} $*"; }

# ─── Preflight ───────────────────────────────────────────────────────────────

if [ ! -d "$COMFY_DIR" ]; then
    err "ComfyUI not found at $COMFY_DIR — are you on a RunPod ComfyUI template?"
    exit 1
fi

log "Installing aria2 for fast downloads..."
if command -v aria2c &>/dev/null; then
    HAS_ARIA2=true
    log "aria2c already installed"
else
    apt-get update -qq </dev/null && apt-get install -y -qq aria2 </dev/null && HAS_ARIA2=true || warn "aria2 install failed, falling back to wget"
fi

# ─── Download helper ─────────────────────────────────────────────────────────

download() {
    local url="$1"
    local dest="$2"

    if [ -f "$dest" ] && [ -s "$dest" ]; then
        log "Exists, skipping: $(basename "$dest")"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    local filename
    filename=$(basename "$dest")

    if $HAS_ARIA2; then
        aria2c -x 16 -s 16 --min-split-size=50M -c -d "$(dirname "$dest")" -o "$filename" "$url" </dev/null || {
            err "Failed: $filename"
            return 1
        }
    else
        wget -c -q --show-progress -O "$dest" "$url" </dev/null || {
            err "Failed: $filename"
            return 1
        }
    fi
    ok "$filename"
}

# ─── Custom Nodes ────────────────────────────────────────────────────────────

REPOS=(
    "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
    "https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
    "https://github.com/kijai/ComfyUI-KJNodes.git"
    "https://github.com/rgthree/rgthree-comfy.git"
    "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
    "https://github.com/cubiq/ComfyUI_essentials.git"
    "https://github.com/kijai/ComfyUI-segment-anything-2.git"
    "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git"
    "https://github.com/chrisgoringe/cg-use-everywhere.git"
)

echo ""
echo "============================================"
echo " Installing Custom Nodes (${#REPOS[@]})"
echo "============================================"

node_ok=0
failed_nodes=()

for repo_url in "${REPOS[@]}"; do
    repo_name=$(basename "$repo_url" .git)
    target="${CUSTOM_NODES_DIR}/${repo_name}"
    node_err=""

    # Update if we have a .git dir; if that fails, drop the dir and re-clone.
    # Shallow clones break under upstream rebases, so pull --ff-only can fail
    # even though the repo is otherwise fine.
    if [ -d "$target/.git" ]; then
        log "Updating $repo_name..."
        if ! git -C "$target" pull --ff-only -q </dev/null; then
            warn "pull failed for $repo_name, re-cloning"
            rm -rf "$target"
        fi
    fi

    if [ ! -d "$target/.git" ]; then
        # Clean up any stale/partial directory (prior clone that aborted mid-way).
        [ -e "$target" ] && rm -rf "$target"
        log "Cloning $repo_name..."
        git clone --depth 1 -q "$repo_url" "$target" </dev/null || node_err="git clone failed"
    fi

    if [ -z "$node_err" ] && [ -f "$target/requirements.txt" ]; then
        log "  pip install for $repo_name..."
        pip install -q -r "$target/requirements.txt" </dev/null || node_err="pip install failed"
    fi

    if [ -z "$node_err" ] && [ -f "$target/install.py" ]; then
        log "  running install.py for $repo_name..."
        "$PYTHON_BIN" "$target/install.py" </dev/null || node_err="install.py failed"
    fi

    if [ -n "$node_err" ]; then
        err "  ✗ $repo_name: $node_err"
        failed_nodes+=("$repo_name ($node_err)")
    else
        ok "  ✓ $repo_name"
        node_ok=$((node_ok + 1))
    fi
done

# ─── Model Downloads ─────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo " Downloading Models"
echo "============================================"

declare -A MODELS

# Diffusion model (~18 GB)
MODELS["${MODELS_DIR}/diffusion_models/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors"]="https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/Wan22Animate/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors"

# Text encoder (~11 GB) — workflow expects "kj-" prefix
MODELS["${MODELS_DIR}/text_encoders/kj-umt5-xxl-enc-bf16.safetensors"]="https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors"

# VAE
MODELS["${MODELS_DIR}/vae/wan_2.1_vae.safetensors"]="https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"

# CLIP Vision
MODELS["${MODELS_DIR}/clip_vision/clip_vision_h.safetensors"]="https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"

# LoRAs
MODELS["${MODELS_DIR}/loras/WanAnimate_relight_lora_fp16_resized_from_128_to_dynamic_22.safetensors"]="https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22_relight/WanAnimate_relight_lora_fp16_resized_from_128_to_dynamic_22.safetensors"
MODELS["${MODELS_DIR}/loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"]="https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"

# Detection (YOLO + ViTPose)
MODELS["${MODELS_DIR}/detection/yolov10m.onnx"]="https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx"
MODELS["${MODELS_DIR}/detection/vitpose-l-wholebody.onnx"]="https://huggingface.co/JunkyByte/easy_ViTPose/resolve/main/onnx/wholebody/vitpose-l-wholebody.onnx"

# SAM 2.1 (for ComfyUI-segment-anything-2)
MODELS["${MODELS_DIR}/sam2/sam2.1_hiera_base_plus.safetensors"]="https://huggingface.co/Kijai/sam2-safetensors/resolve/main/sam2.1_hiera_base_plus.safetensors"

# Upscale
MODELS["${MODELS_DIR}/upscale_models/4x_foolhardy_Remacri.pth"]="https://huggingface.co/FacehugmanIII/4x_foolhardy_Remacri/resolve/main/4x_foolhardy_Remacri.pth"

job_count=0
dl_pids=()

for dest in "${!MODELS[@]}"; do
    url="${MODELS[$dest]}"
    download "$url" "$dest" &
    dl_pids+=($!)
    job_count=$((job_count + 1))

    if ((job_count >= MAX_PARALLEL)); then
        wait -n 2>/dev/null || true
        job_count=$((job_count - 1))
    fi
done

for pid in "${dl_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# ─── Verification ─────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo " Verification"
echo "============================================"

model_ok=0
model_fail=0
missing=()

for dest in "${!MODELS[@]}"; do
    fname=$(basename "$dest")
    if [ -f "$dest" ] && [ -s "$dest" ]; then
        ok "  ✓ $fname"
        model_ok=$((model_ok + 1))
    else
        err "  ✗ $fname"
        missing+=("$fname")
        model_fail=$((model_fail + 1))
    fi
done

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo " Setup Complete"
echo "============================================"
echo ""
echo "  Custom Nodes:  ${node_ok}/${#REPOS[@]} installed"
echo "  Models:        ${model_ok}/$((model_ok + model_fail)) downloaded"
echo "  Disk usage:    $(du -sh "${MODELS_DIR}" 2>/dev/null | cut -f1)"
echo "  Elapsed:       ${SECONDS}s"
echo ""

if [ ${#failed_nodes[@]} -gt 0 ]; then
    warn "Failed custom nodes:"
    for n in "${failed_nodes[@]}"; do
        warn "  - $n"
    done
fi

if [ ${#missing[@]} -gt 0 ]; then
    warn "Missing model files: ${missing[*]}"
fi

if [ ${#failed_nodes[@]} -gt 0 ] || [ ${#missing[@]} -gt 0 ]; then
    warn "Re-run this script to retry."
fi

echo ""
echo "  Start ComfyUI:"
echo "    cd ${COMFY_DIR} && ${PYTHON_BIN} main.py --listen 0.0.0.0 --port 8188"
echo ""
