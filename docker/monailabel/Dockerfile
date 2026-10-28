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
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11

# ── PyTorch 2.7 — CUDA 12.8 wheels (Blackwell sm_120 support) ──
RUN pip install --no-cache-dir \
    torch==2.7.0 \
    torchvision==0.22.0 \
    torchaudio==2.7.0 \
    --index-url https://download.pytorch.org/whl/cu128

# ── MONAI Core (all extras) ──────────────────────────────────
RUN pip install --no-cache-dir \
    "monai[all]==1.4.0"

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
