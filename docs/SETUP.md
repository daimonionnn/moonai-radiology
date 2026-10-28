# Setup Guide

## Prerequisites

### 1. NVIDIA Driver (≥ 570 for Blackwell GPUs — RTX PRO 6000, RTX 5090)

```bash
# Check current driver
nvidia-smi

# If needed, install latest driver
sudo apt install ubuntu-drivers-common
sudo ubuntu-drivers install
# OR target a specific version:
sudo apt install nvidia-driver-570

sudo reboot
```

### 2. Docker Engine

```bash
# Remove old versions
sudo apt remove docker docker-engine docker.io containerd runc

# Install via official script
curl -fsSL https://get.docker.com | sudo bash
sudo usermod -aG docker $USER
newgrp docker
```

### 3. Docker Compose v2

```bash
sudo apt install docker-compose-plugin
docker compose version   # should show 2.x
```

### 4. NVIDIA Container Toolkit

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmour -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi
```

### 5. NGC API Key — *not required by default*

The default stack (MONAI Label, Orthanc, OHIF) needs **no NGC account**. You only
need an NGC key if you enable the optional Triton/Holoscan services — in that case
follow [OPTIONAL_SERVICES.md](OPTIONAL_SERVICES.md).

---

## Installation

### Step 1 — Clone / Enter project

```bash
cd /path/to/moonai-radiology
```

### Step 2 — Configure environment

```bash
# Edit docker/.env with your settings
nano docker/.env

# Key settings to verify:
#   NGC_API_KEY=<your-key>
#   LLM_BASE_URL=http://localhost:1234
#   LLM_MODEL=<model-name-in-lm-studio>
```

### Step 3 — Run full setup

```bash
./scripts/setup.sh
```

This will:
- Verify driver + Docker versions
- Log in to NGC
- Pull all Docker images
- Build the custom MONAI Label image (CUDA 12.8 + PyTorch 2.6)

> First build takes **10–20 minutes** (downloads ~15 GB of layers).

### Step 4 — Download pretrained models

```bash
./scripts/download-models.sh
```

Downloads 11 MONAI Zoo bundles (~5–15 GB total) to `./models/bundles/`.

### Step 5 — Start the platform

```bash
./scripts/start.sh
```

Verify everything is running:

```bash
./scripts/status.sh
```

---

## 3D Slicer Installation

```bash
./scripts/install-slicer.sh
```

This downloads 3D Slicer 5.10.0 to `~/slicer/` and creates a desktop launcher.

### Install MONAI Label Plugin (Extension Manager — recommended)

1. Launch 3D Slicer: `slicer3d`
2. **View → Extension Manager**
3. Search: `MONAI Label`
4. Click **Install** → restart Slicer when prompted

### Install Manually

```bash
git clone https://github.com/Project-MONAI/MONAILabel.git ~/MONAILabel
```

In Slicer: **Edit → Application Settings → Modules → Additional Module Paths**  
Add: `~/MONAILabel/plugins/slicer/MONAILabel` → restart Slicer.

### Connect to MONAI Label Server

1. In Slicer, open the **MONAI Label** module (search in module finder)
2. Server address: `http://localhost:8000`
3. Click **Refresh** — the module loads available models from the server

---

## NIfTI Dataset Support

MONAI Label can read studies directly from a local folder of NIfTI files.  
No DICOM conversion needed.

**Configure in `docker/.env`:**

```bash
MONAILABEL_STUDIES_MODE=local
MONAILABEL_STUDIES_LOCAL_PATH=/workspace/datasets/nifti
```

Place your `.nii` or `.nii.gz` files in `./datasets/nifti/` and restart:

```bash
./scripts/restart.sh monailabel
```

**Switch to DICOMweb (Orthanc) mode:**

```bash
MONAILABEL_STUDIES_MODE=dicomweb
```

And restart MONAI Label. It will connect to Orthanc at `http://orthanc:8042/dicom-web`.

---

## Uploading DICOM Data to Orthanc

**Web UI:** http://localhost:8042 → Upload → drag-and-drop DICOM files or ZIP

**Command line (curl):**
```bash
curl -u "admin:$ORTHANC_PASSWORD" \
     -X POST http://localhost:8042/instances \
     -H "Content-Type: application/dicom" \
     --data-binary @study.dcm
```

**3D Slicer C-STORE:**  
In Slicer → DICOM module → Send to: `localhost:4242` AET: `MONAI`

**dcmtk storescu:**
```bash
storescu -aet SLICER -aec MONAI localhost 4242 /path/to/dicom/*.dcm
```

---

## Verify Installation

```bash
# MONAI Label info
curl http://localhost:8000/info | python3 -m json.tool

# List available models
curl http://localhost:8000/info | python3 -c "
import json,sys
info=json.load(sys.stdin)
for k in info.get('models',{}).keys(): print(' -', k)
"

# GPU check inside container
docker exec monailabel python3 -c "
import torch
print('CUDA available:', torch.cuda.is_available())
print('GPU:', torch.cuda.get_device_name(0))
print('CUDA version:', torch.version.cuda)
"
```
