FROM nvidia/cuda:12.2.2-cudnn8-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=C
ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV NVIDIA_VISIBLE_DEVICES=all

# ---------------------------------------------------------
# System packages
# ---------------------------------------------------------

RUN apt-get update -y --fix-missing \
    && apt-get install -y --no-install-recommends \
        apt-utils \
        locales \
        ca-certificates \
        build-essential \
        python3-dev \
        python3-pip \
        python3-venv \
        unzip \
        wget \
        curl \
        zip \
        zlib1g \
        zlib1g-dev \
        gnupg \
        rsync \
        git \
        sudo \
        libglib2.0-0 \
        socat \
        pkg-config \
        libcairo2-dev \
        libpango1.0-dev \
        libjpeg-dev \
        libpng-dev \
        libffi-dev \
        libsm6 \
        libxext6 \
        libxrender1 \
        xdg-utils \
        libglvnd0 \
        libglvnd-dev \
        libegl1-mesa-dev \
        libvulkan1 \
        libvulkan-dev \
        ffmpeg \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# NVIDIA EGL / Vulkan ICD configuration
RUN mkdir -p /usr/share/glvnd/egl_vendor.d \
    && echo '{"file_format_version":"1.0.0","ICD":{"library_path":"libEGL_nvidia.so.0"}}' \
       > /usr/share/glvnd/egl_vendor.d/10_nvidia.json \
    && mkdir -p /usr/share/vulkan/icd.d \
    && echo '{"file_format_version":"1.0.0","ICD":{"library_path":"libGLX_nvidia.so.0","api_version":"1.3"}}' \
       > /usr/share/vulkan/icd.d/nvidia_icd.json

ENV MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA

# ---------------------------------------------------------
# Image information
# ---------------------------------------------------------

ARG BUILD_BASE="ubuntu22_cuda12.2"
ARG COMFYUI_NVIDIA_DOCKER_VERSION="stalkervr-ubuntu22-cuda12.2"

RUN echo "${BUILD_BASE}" > /etc/build_base.txt \
    && chmod 555 /etc/build_base.txt

RUN printf '%s\n' \
    "DOCKER_FROM: nvidia/cuda:12.2.2-cudnn8-devel-ubuntu22.04" \
    "CUDA: 12.2" \
    "CUDNN: ${NV_CUDNN_PACKAGE_NAME} (${NV_CUDNN_VERSION})" \
    > /etc/image_base.txt

LABEL comfyui-nvidia-docker-build-from="${BUILD_BASE}"
LABEL comfyui-nvidia-docker-build="${COMFYUI_NVIDIA_DOCKER_VERSION}"

# ---------------------------------------------------------
# ComfyUI runtime user
# ---------------------------------------------------------

RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

RUN groupadd -g 1024 comfy \
    && groupadd -g 1025 comfytoo

RUN useradd \
        -u 1024 \
        -d /home/comfy \
        -g comfy \
        -s /bin/bash \
        -m comfy \
    && usermod -G users comfy \
    && adduser comfy sudo

RUN useradd \
        -u 1025 \
        -d /home/comfytoo \
        -g comfytoo \
        -s /bin/bash \
        -m comfytoo \
    && usermod -G users comfytoo \
    && adduser comfytoo sudo

ENV COMFYUSER_DIR=/comfy

RUN mkdir -p "${COMFYUSER_DIR}" \
    && echo "${COMFYUSER_DIR}" > /etc/comfyuser_dir \
    && chmod 555 /etc/comfyuser_dir

# ---------------------------------------------------------
# ComfyUI startup
# ---------------------------------------------------------

COPY --chmod=555 init.bash /comfyui-nvidia_init.bash
COPY --chmod=555 config.sh /comfyui-nvidia_config.sh

EXPOSE 8188

USER comfytoo

ENTRYPOINT ["/comfyui-nvidia_init.bash"]
