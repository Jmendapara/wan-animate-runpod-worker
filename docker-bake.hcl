variable "DOCKERHUB_REPO" {
  default = "jmendapara"
}

variable "DOCKERHUB_IMG" {
  default = "wan-animate-runpod-worker"
}

variable "RELEASE_VERSION" {
  default = "latest"
}

variable "COMFYUI_VERSION" {
  default = "latest"
}

variable "BASE_IMAGE" {
  default = "nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04"
}

variable "CUDA_VERSION_FOR_COMFY" {
  default = "12.6"
}

variable "ENABLE_PYTORCH_UPGRADE" {
  default = "true"
}

variable "PYTORCH_INDEX_URL" {
  default = "https://download.pytorch.org/whl/cu126"
}

group "default" {
  targets = ["wan-animate"]
}

target "wan-animate" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "final"
  platforms  = ["linux/amd64"]
  args = {
    BASE_IMAGE             = "${BASE_IMAGE}"
    COMFYUI_VERSION        = "${COMFYUI_VERSION}"
    CUDA_VERSION_FOR_COMFY = "${CUDA_VERSION_FOR_COMFY}"
    ENABLE_PYTORCH_UPGRADE = "${ENABLE_PYTORCH_UPGRADE}"
    PYTORCH_INDEX_URL      = "${PYTORCH_INDEX_URL}"
  }
  tags = ["${DOCKERHUB_REPO}/${DOCKERHUB_IMG}:${RELEASE_VERSION}"]
}

# Blackwell variant (RTX PRO 6000 96 GB, sm_120): CUDA 12.8 + PyTorch cu128.
target "wan-animate-blackwell" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "final"
  platforms  = ["linux/amd64"]
  args = {
    BASE_IMAGE             = "nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04"
    COMFYUI_VERSION        = "${COMFYUI_VERSION}"
    CUDA_VERSION_FOR_COMFY = ""
    ENABLE_PYTORCH_UPGRADE = "true"
    PYTORCH_INDEX_URL      = "https://download.pytorch.org/whl/cu128"
  }
  tags = ["${DOCKERHUB_REPO}/${DOCKERHUB_IMG}:${RELEASE_VERSION}-blackwell"]
}
