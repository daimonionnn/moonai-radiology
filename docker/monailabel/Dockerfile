# ============================================================
#  MONAI Label Custom Image
#  Base:  CUDA 12.8 + cuDNN on Ubuntu 22.04
#  GPU:   Blackwell (sm_120: RTX PRO 6000, RTX 5090) — requires CUDA 12.8+
# ============================================================

FROM nvcr.io/nvidia/cuda:12.8.0-cudnn-devel-ubuntu22.04

LABEL maintainer="MONAI Platform"
LABEL description="MONAI Label + Core + Deploy + TorchXRayVision on CUDA 12.8"
LABEL cuda.version="12.8"

# ── System deps ─────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive
# The current CUDA base image ships /tmp as 1755: apt's sandbox user cannot write its
# temp files there and every 'apt-get update' fails with "repository is not signed".
RUN chmod 1777 /tmp
# Ubuntu 22.04's own python3.11 is the pre-release 3.11.0rc1, whose enum bug crashes
# pytorch-ignite (needed by VISTA3D and other bundles) — take a final 3.11.x from the
# deadsnakes PPA instead.
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common gpg-agent \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-dev \
    python3.11-distutils \
    python3-pip \
    git \
    wget \
    curl \
    unzip \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    ffmpeg \
    dcmtk \
    && rm -rf /var/lib/apt/lists/*

# Set python3.11 as default
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1 \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11 \
    && python3.11 -c "import sys; assert sys.version_info.releaselevel == 'final', sys.version"

# ── PyTorch — CUDA 12.8 wheels (Blackwell sm_120 support) ─────
# MONAI 1.6 needs torch >= 2.8. 2.11.0+cu128 is the version already verified on the
# reference GPU in the host venvs (TotalSegmentator, nnInteractive).
ARG TORCH_VERSION=2.11.0
ARG TORCHVISION_VERSION=0.26.0
RUN pip install --no-cache-dir \
    torch==${TORCH_VERSION} \
    torchvision==${TORCHVISION_VERSION} \
    torchaudio==${TORCH_VERSION} \
    --index-url https://download.pytorch.org/whl/cu128

# ── MONAI Core (all extras) ──────────────────────────────────
# MONAI Label 0.8.5 only requires monai>=1.4.0.
ARG MONAI_VERSION=1.6.1
# software-properties-common (for the deadsnakes PPA) pulls apt's python3-blinker, which
# pip cannot uninstall ("distutils installed project") — install ours alongside it.
RUN pip install --no-cache-dir --ignore-installed blinker \
    && pip install --no-cache-dir \
    "monai[all]==${MONAI_VERSION}"
# monai[all] 1.6 pulls cuCIM for CUDA 13 (cucim-cu13 + cupy-cuda13x + nvimgcodec-cu13),
# which conflicts with the CUDA 12.8 stack of this image — use the CUDA 12 build instead.
RUN pip uninstall -y cucim-cu13 cupy-cuda13x nvidia-nvimgcodec-cu13 \
    && pip install --no-cache-dir cucim-cu12 "nvidia-nvimgcodec-cu12[all]"

# MONAI >= 1.5 Spacingd updates every "<key>_*" entry as a metadata dict, but MONAI Label
# 0.8.5 adds "image_path" (a string) → every inference failed with
# "'str' object has no attribute 'update'". Only update entries that are dicts.
RUN python3 -c "import monai.transforms.spatial.dictionary as d; p = d.__file__; t = open(p).read(); old = 'd[meta_key].update(d[key].meta)'; assert t.count(old) == 1, 'MONAI changed - review this patch'; open(p, 'w').write(t.replace(old, old + ' if isinstance(d[meta_key], dict) else None'))"

# ── MONAI Label ──────────────────────────────────────────────
RUN pip install --no-cache-dir \
    "monailabel==0.8.5"

# ── MONAI Deploy App SDK (pulls Holoscan SDK) ────────────────
RUN pip install --no-cache-dir \
    "monai-deploy-app-sdk==3.0.0"

# ── TorchXRayVision — 14-pathology CXR / RTG classifier ─────
RUN pip install --no-cache-dir \
    torchxrayvision \
    scikit-image \
    pydicom \
    SimpleITK \
    nibabel \
    pynrrd \
    highdicom

# ── Utilities  ───────────────────────────────────────────────
RUN pip install --no-cache-dir \
    requests \
    httpx \
    "openai>=1.0.0" \
    tensorboard \
    pandas \
    matplotlib \
    seaborn \
    tqdm \
    pydantic \
    "fastapi>=0.100.0" \
    uvicorn \
    python-multipart

# ── Application files ────────────────────────────────────────
WORKDIR /workspace

# Copy custom inference wrappers and entrypoint
COPY entrypoint.sh /entrypoint.sh
COPY xrayvision_infer.py /workspace/xrayvision_infer.py

RUN chmod +x /entrypoint.sh

# Create workspace directories
RUN mkdir -p \
    /workspace/apps \
    /workspace/datasets \
    /workspace/bundles \
    /workspace/logs \
    /workspace/tensorboard

# ── Default env ──────────────────────────────────────────────
ENV MONAILABEL_APP=monaibundle
ENV MONAILABEL_MODELS=brats_mri_segmentation,lung_nodule_ct_detection
ENV MONAILABEL_STUDIES_MODE=local
ENV MONAILABEL_STUDIES_LOCAL_PATH=/workspace/datasets
ENV MONAILABEL_PRELOAD=true
ENV MONAILABEL_LOG_LEVEL=INFO
ENV PYTHONUNBUFFERED=1

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
