# Build argument for base image selection
ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

# Stage 1: Base image with ComfyUI, custom nodes, and runtime deps
FROM ${BASE_IMAGE} AS base

# Build arguments
ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL
ARG PYTORCH_VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# System dependencies
RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
    git \
    wget \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    libsndfile1 \
    ffmpeg \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# Install uv and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# All subsequent python/pip calls use the venv
ENV PATH="/opt/venv/bin:${PATH}"

# comfy-cli + base pip deps
RUN uv pip install comfy-cli pip setuptools wheel

# Install ComfyUI (with optional PyTorch pin for specific CUDA versions)
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi && \
    if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ] && [ -n "${PYTORCH_VERSION}" ]; then \
      uv pip install --force-reinstall torch==${PYTORCH_VERSION} torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    elif [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi && \
    rm -rf /root/.cache/pip /root/.cache/uv /root/.cache/comfy-cli /tmp/* && \
    uv cache clean

WORKDIR /comfyui

# comfy-cli's `install` doesn't always pull the full ComfyUI requirements.txt,
# so newer deps (e.g. sqlalchemy/alembic/aiosqlite for the asset DB) go missing
# and ComfyUI crashes on startup. Install them explicitly from ComfyUI's own
# requirements file.
RUN if [ -f /comfyui/requirements.txt ]; then \
        /opt/venv/bin/pip install -q --root-user-action=ignore -r /comfyui/requirements.txt; \
    fi && \
    rm -rf /root/.cache/pip /root/.cache/uv && \
    uv cache clean

# Network-volume model-path config
ADD src/extra_model_paths.yaml ./

# Install the 7 custom-node repos this workflow needs.
# Using inline git clone (not comfy-node-install) because these are pinned repos
# that aren't all on the Comfy registry, and we want deterministic builds.
# All pip installs go through /opt/venv/bin/pip — this is what broke us when
# testing setup.sh on a slim pod (installs landed in system site-packages
# and the running ComfyUI venv never saw them).
RUN cd /comfyui/custom_nodes && \
    for repo in \
        https://github.com/kijai/ComfyUI-WanVideoWrapper.git \
        https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git \
        https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
        https://github.com/kijai/ComfyUI-KJNodes.git \
        https://github.com/ltdrdata/ComfyUI-Impact-Pack.git \
        https://github.com/cubiq/ComfyUI_essentials.git \
        https://github.com/kijai/ComfyUI-segment-anything-2.git \
    ; do \
        name=$(basename "$repo" .git); \
        echo "=== Cloning $name ==="; \
        git clone --depth 1 "$repo" "$name"; \
        if [ -f "$name/requirements.txt" ]; then \
            /opt/venv/bin/pip install -q --root-user-action=ignore -r "$name/requirements.txt"; \
        fi; \
    done && \
    rm -rf /root/.cache/pip /root/.cache/uv && \
    uv cache clean

WORKDIR /

# RunPod handler runtime deps (boto3 added for R2 input downloads)
RUN uv pip install runpod~=1.7.12 requests websocket-client boto3

# Application code
ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh

# Utility scripts
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-node-install /usr/local/bin/comfy-manager-set-mode

ENV PIP_NO_INPUT=1

CMD ["/start.sh"]

# Stage 2: Final image — download all Wan Animate models via hf_hub_download
FROM base AS final

WORKDIR /comfyui

# Create the model directory layout the workflow expects
RUN mkdir -p \
    models/diffusion_models \
    models/text_encoders \
    models/vae \
    models/clip_vision \
    models/loras \
    models/detection \
    models/sam2

# All model repos below are public — no HUGGINGFACE_ACCESS_TOKEN needed.
# URLs mirror the validated MODELS array from setup.sh. The 4x_foolhardy_Remacri
# upscaler is omitted because the fixed workflow removed the upscaling step.
RUN uv pip install "huggingface_hub[hf_xet]" && \
    python -c "\
from huggingface_hub import hf_hub_download; \
import shutil, os; \
hf_hub_download(repo_id='Kijai/WanVideo_comfy_fp8_scaled', filename='Wan22Animate/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors', local_dir='/comfyui/models/diffusion_models-tmp'); \
shutil.move('/comfyui/models/diffusion_models-tmp/Wan22Animate/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors', '/comfyui/models/diffusion_models/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors'); \
shutil.rmtree('/comfyui/models/diffusion_models-tmp', ignore_errors=True); \
\
hf_hub_download(repo_id='Kijai/WanVideo_comfy', filename='umt5-xxl-enc-bf16.safetensors', local_dir='/comfyui/models/text_encoders-tmp'); \
shutil.move('/comfyui/models/text_encoders-tmp/umt5-xxl-enc-bf16.safetensors', '/comfyui/models/text_encoders/kj-umt5-xxl-enc-bf16.safetensors'); \
shutil.rmtree('/comfyui/models/text_encoders-tmp', ignore_errors=True); \
\
hf_hub_download(repo_id='Comfy-Org/Wan_2.1_ComfyUI_repackaged', filename='split_files/vae/wan_2.1_vae.safetensors', local_dir='/comfyui/models/vae-tmp'); \
shutil.move('/comfyui/models/vae-tmp/split_files/vae/wan_2.1_vae.safetensors', '/comfyui/models/vae/wan_2.1_vae.safetensors'); \
shutil.rmtree('/comfyui/models/vae-tmp', ignore_errors=True); \
\
hf_hub_download(repo_id='Comfy-Org/Wan_2.1_ComfyUI_repackaged', filename='split_files/clip_vision/clip_vision_h.safetensors', local_dir='/comfyui/models/clip_vision-tmp'); \
shutil.move('/comfyui/models/clip_vision-tmp/split_files/clip_vision/clip_vision_h.safetensors', '/comfyui/models/clip_vision/clip_vision_h.safetensors'); \
shutil.rmtree('/comfyui/models/clip_vision-tmp', ignore_errors=True); \
\
hf_hub_download(repo_id='Kijai/WanVideo_comfy', filename='LoRAs/Wan22_relight/WanAnimate_relight_lora_fp16_resized_from_128_to_dynamic_22.safetensors', local_dir='/comfyui/models/loras-tmp'); \
shutil.move('/comfyui/models/loras-tmp/LoRAs/Wan22_relight/WanAnimate_relight_lora_fp16_resized_from_128_to_dynamic_22.safetensors', '/comfyui/models/loras/WanAnimate_relight_lora_fp16_resized_from_128_to_dynamic_22.safetensors'); \
shutil.rmtree('/comfyui/models/loras-tmp', ignore_errors=True); \
\
hf_hub_download(repo_id='Kijai/WanVideo_comfy', filename='Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors', local_dir='/comfyui/models/loras-tmp'); \
shutil.move('/comfyui/models/loras-tmp/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors', '/comfyui/models/loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors'); \
shutil.rmtree('/comfyui/models/loras-tmp', ignore_errors=True); \
\
hf_hub_download(repo_id='Wan-AI/Wan2.2-Animate-14B', filename='process_checkpoint/det/yolov10m.onnx', local_dir='/comfyui/models/detection-tmp'); \
shutil.move('/comfyui/models/detection-tmp/process_checkpoint/det/yolov10m.onnx', '/comfyui/models/detection/yolov10m.onnx'); \
shutil.rmtree('/comfyui/models/detection-tmp', ignore_errors=True); \
\
hf_hub_download(repo_id='JunkyByte/easy_ViTPose', filename='onnx/wholebody/vitpose-l-wholebody.onnx', local_dir='/comfyui/models/detection-tmp'); \
shutil.move('/comfyui/models/detection-tmp/onnx/wholebody/vitpose-l-wholebody.onnx', '/comfyui/models/detection/vitpose-l-wholebody.onnx'); \
shutil.rmtree('/comfyui/models/detection-tmp', ignore_errors=True); \
\
hf_hub_download(repo_id='Kijai/sam2-safetensors', filename='sam2.1_hiera_base_plus.safetensors', local_dir='/comfyui/models/sam2'); \
" && \
    rm -rf /root/.cache/huggingface /tmp/* && \
    uv cache clean
