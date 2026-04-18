#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Build the wan-animate-runpod-worker Docker image on a build host (Hetzner,
# RunPod GPU Pod, anywhere with Docker + buildx) and push to Docker Hub.
#
# Usage:
#
#   export DOCKERHUB_USERNAME="your-dockerhub-user"
#   export DOCKERHUB_TOKEN="your-dockerhub-access-token"
#   export IMAGE_TAG="your-user/wan-animate-runpod-worker:latest"
#   bash build-on-pod.sh
#
# Optional:
#   CUDA_LEVEL=12.8       # Use CUDA 12.8 base for Blackwell (RTX PRO 6000)
#   PYTORCH_VERSION=2.5.0 # Pin PyTorch; default is "latest" on the index
#   BRANCH=main           # Git branch to build from
#   REPO_URL=...          # Override for forks
#
# Prerequisites:
#   - Docker + buildx
#   - ~120 GB free disk (final image is ~40 GB; build cache pushes total up).
# =============================================================================

REPO_URL="${REPO_URL:-https://github.com/Jmendapara/wan-animate-runpod-worker.git}"
BRANCH="${BRANCH:-main}"
COMFYUI_VERSION="${COMFYUI_VERSION:-latest}"

: "${DOCKERHUB_USERNAME:?Set DOCKERHUB_USERNAME}"
: "${DOCKERHUB_TOKEN:?Set DOCKERHUB_TOKEN}"
: "${IMAGE_TAG:?Set IMAGE_TAG (e.g. yourdockerhubuser/wan-animate-runpod-worker:latest)}"

echo "============================================="
echo " wan-animate-runpod-worker builder"
echo "============================================="
echo "  Repo:         ${REPO_URL}"
echo "  Branch:       ${BRANCH}"
echo "  ComfyUI ver:  ${COMFYUI_VERSION}"
echo "  Image tag:    ${IMAGE_TAG}"
echo "  CUDA level:   ${CUDA_LEVEL:-12.6}"
echo "============================================="

# ---- Step 1: Docker + buildx ----
if ! command -v docker &>/dev/null || ! docker buildx version &>/dev/null 2>&1; then
    echo "[1/5] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
else
    echo "[1/5] Docker already available: $(docker --version)"
fi

if ! docker info &>/dev/null 2>&1; then
    echo "[1/5] Starting Docker daemon..."
    if ! systemctl start docker 2>/dev/null; then
        dockerd &>/dev/null &
        sleep 5
    fi
fi
docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon is not running."; exit 1; }

# ---- Step 2: Docker Hub login ----
echo "[2/5] Logging into Docker Hub..."
echo "${DOCKERHUB_TOKEN}" | docker login --username "${DOCKERHUB_USERNAME}" --password-stdin

# ---- Step 3: Clone repo ----
WORK_DIR="/tmp/wan-animate-build-workspace"
if [ -d "${WORK_DIR}" ]; then
    rm -rf "${WORK_DIR}"
fi
echo "[3/5] Cloning ${REPO_URL} (branch ${BRANCH})..."
git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${WORK_DIR}"
cd "${WORK_DIR}"

# ---- Step 4: Build ----
echo "[4/5] Building Docker image (this will take a while — ~35 GB of models downloaded during final stage)..."

BUILD_ARGS=(
    --platform linux/amd64
    --target final
    --build-arg "COMFYUI_VERSION=${COMFYUI_VERSION}"
)

CUDA_LEVEL="${CUDA_LEVEL:-12.6}"
PYTORCH_VERSION="${PYTORCH_VERSION:-}"

if [ "${CUDA_LEVEL}" = "12.8" ]; then
    BUILD_ARGS+=(
        --build-arg "BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04"
        --build-arg "ENABLE_PYTORCH_UPGRADE=true"
        --build-arg "PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu128"
        --build-arg "PYTORCH_VERSION=${PYTORCH_VERSION}"
    )
    echo "       Using CUDA 12.8 base + PyTorch cu128 (Blackwell; driver >= 570)"
else
    BUILD_ARGS+=(
        --build-arg "BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04"
        --build-arg "CUDA_VERSION_FOR_COMFY=12.6"
        --build-arg "ENABLE_PYTORCH_UPGRADE=true"
        --build-arg "PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu126"
        --build-arg "PYTORCH_VERSION=${PYTORCH_VERSION}"
    )
    echo "       Using CUDA 12.6 base + PyTorch cu126 (A100/H100; driver >= 560)"
fi

# Free disk before build
docker system prune -af --volumes 2>/dev/null || true
docker builder prune -af 2>/dev/null || true
echo "       Disk free: $(df -h /var/lib/docker 2>/dev/null | tail -1 | awk '{print $4}')"

docker buildx use default 2>/dev/null || true
docker buildx build "${BUILD_ARGS[@]}" -t "${IMAGE_TAG}" .

echo "[4/5] Build complete: $(docker images "${IMAGE_TAG}" --format '{{.Size}}')"

# ---- Step 5: Push ----
echo "[5/5] Pushing ${IMAGE_TAG} to Docker Hub..."
docker push "${IMAGE_TAG}"

echo ""
echo "============================================="
echo " SUCCESS"
echo "============================================="
echo "  Image pushed: ${IMAGE_TAG}"
echo ""
echo "  Next steps:"
echo "    1. https://www.runpod.io/console/serverless"
echo "    2. Create endpoint with container image: ${IMAGE_TAG}"
if [ "${CUDA_LEVEL}" = "12.8" ]; then
echo "    3. Pick GPU: RTX PRO 6000 Blackwell 96 GB"
else
echo "    3. Pick GPU: H100 80 GB or A100 80 GB"
fi
echo "    4. Set Min Workers=0, Max Workers=1"
echo "    5. Add env vars: BUCKET_ENDPOINT_URL, BUCKET_ACCESS_KEY_ID,"
echo "         BUCKET_SECRET_ACCESS_KEY, R2_BUCKET_NAME"
echo "    6. Destroy this build server to stop charges!"
echo "============================================="
