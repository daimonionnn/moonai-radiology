> **Historical document.** The original project brief and the implementation plan
> it produced (early 2026). Kept for context only; the current setup is described in
> [SETUP](../SETUP.md) and [ARCHITECTURE](../ARCHITECTURE.md), and some details below
> (Triton/Holoscan in the default stack, `ohif/app:latest`) are out of date.

INSTALLING MONAI FRAMEWORK ON UBUNTU WITH DOCKER
I need to install MONAI framework locally here on linux UBUNTU - monai server, monai core, monai label, monai deploy. radiology app, nvidia holoscan, Also 3D slicer. I have nVidia 5090 32GB VRAM here locally and 64 GB system RAM. I want some container, I expect docker is the way to go, right ? Need to map folders in project to folders in to docker container. I created for now folder apps for apps and datasets with my own example MRI and CT data (planned for training). You can move and rename these folders. I also would like to use some pretrained models - MONAI Zoo. I would like to label mcr, ct, rtg, mamography data, then train and connect it my LLM model for inference. I expect using MONAI zoo I can have some basic system that can run some tumor diagnostic when I provide dicom images. Please create some good structured deploy scripts for docker and other needed aps. Also some shell scripts to run/deploy these components for easy management and configuration. Script to easy start docker container/containers. Also create documentation about this project and how to run/deploy, how to start monai server and other related aps, how to use UI / web page interface. Then how to label radiology models, how to train, then how to use it for tumors / abnormal findings/pathology detection, etc.




---------------------------------------------------------------------------------------------------------
Plan: MONAI Medical Imaging AI Platform — Full Stack Setup
TL;DR: Build a production-grade MONAI medical imaging platform using Docker Compose with 5 services (MONAI Label, OHIF Viewer, Orthanc DICOM server, Triton Inference, and a custom base image). MONAI Deploy/Holoscan runs as a CLI toolchain on the host or per-app container. 3D Slicer runs natively on the Ubuntu desktop and connects to MONAI Label at localhost:8000. A custom Dockerfile is required because projectmonai/monailabel:latest is built against CUDA < 12.8, and the RTX 5090 (Blackwell, sm_100) needs CUDA 12.8+. Shell scripts wrap all lifecycle operations. Full documentation covers setup → labeling → training → inference → LLM integration.

Steps

1. Reorganize project structure

Create the following layout under monai:


monai/├── docker/│   ├── docker-compose.yml│   ├── .env│   ├── monailabel/│   │   └── Dockerfile          ← custom image: CUDA 12.8 + PyTorch 2.6 + monailabel│   ├── ohif/│   │   └── app-config.js       ← points to localhost:8000 (MONAI Label)│   └── orthanc/│       └── orthanc.json        ← enables DICOMweb plugin├── apps/                       ← MONAI Label apps (downloaded at runtime)├── datasets/│   ├── ct/                     ← rename ct_data/<your_ct> → here│   └── mri/                    ← rename mri_data/<your_mri> → here├── models/│   ├── bundles/                ← MONAI Zoo .zip bundles│   └── triton/                 ← Triton model repo structure├── scripts/│   ├── setup.sh│   ├── start.sh│   ├── stop.sh│   ├── restart.sh│   ├── status.sh│   ├── logs.sh│   ├── download-models.sh│   ├── install-slicer.sh│   └── build.sh├── storage/│   ├── orthanc-db/│   └── logs/└── docs/    ├── README.md    ├── ARCHITECTURE.md    ├── SETUP.md    ├── LABELING.md    ├── TRAINING.md    ├── INFERENCE.md    └── LLM_INTEGRATION.md
2. Custom Dockerfile — docker/monailabel/Dockerfile

Base: nvcr.io/nvidia/cuda:12.8.0-cudnn-devel-ubuntu22.04
Install: PyTorch 2.6 (cu128 wheel) → monai[all] → monailabel → monai-deploy-app-sdk (pulls Holoscan)
This guarantees RTX 5090 Blackwell sm_100 support.

3. docker/docker-compose.yml — 5 services

Service	Image	Port
monailabel	custom ./docker/monailabel	8000
ohif	ohif/app:latest	3000
orthanc	orthancteam/orthanc:latest	8042 / 4242
triton	nvcr.io/nvidia/tritonserver:25.01-py3	8001/8002/8003
holoscan	nvcr.io/nvidia/clara-holoscan/holoscan:v3.11.0-cuda12-dgpu	(dev/run only)
Volume mounts map apps, datasets, ./models/bundles, ./storage into containers.

4. docker/.env — central config

All tuneable values: MONAILABEL_APP, MONAILABEL_MODELS, MONAILABEL_PORT, CUDA_VISIBLE_DEVICES, NGC credentials, Orthanc auth, etc.

5. Shell scripts — scripts/

scripts/setup.sh — prerequisite check (nvidia-smi, docker, docker compose v2), docker compose pull, docker compose build, create directory tree
scripts/build.sh — rebuild custom MONAI Label image
scripts/download-models.sh — download 8 MONAI Zoo bundles: brats_mri_segmentation, lung_nodule_ct_detection, wholeBody_ct_segmentation, breast_density_classification, pathology_tumor_detection, pathology_nuclei_segmentation_classification, vista3d, swin_unetr_btcv_segmentation
scripts/start.sh — docker compose up -d with health-check feedback; optionally pass --app radiology|monaibundle|pathology to switch MONAI Label app
scripts/stop.sh / scripts/restart.sh
scripts/status.sh — port check, GPU utilization, container health
scripts/logs.sh — tail logs for a chosen service
scripts/install-slicer.sh — download 3D Slicer 5.x AppImage/tarball to host, launch with correct LD_PRELOAD
6. Orthanc config — docker/orthanc/orthanc.json

Enable DICOMweb plugin; configure AET MONAI; set CORS for OHIF & MONAI Label.

7. OHIF config — docker/ohif/app-config.js

DataSources pointing to Orthanc DICOMweb at http://localhost:8042/dicom-web and MONAI Label extension at http://localhost:8000.

8. MONAI Label app selection logic

.env key MONAILABEL_APP switches between:

monaibundle (default, loads Zoo bundles directly — covers MRI/CT/mammography)
radiology (legacy DeepEdit / DeepGrow interactive annotation)
pathology (WSI, connects to QuPath)
9. Documentation — docs/

docs/README.md — overview, quick-start (3 commands), service map, port table
docs/ARCHITECTURE.md — component diagram, data flow (DICOM → Orthanc → MONAI Label → annotation → training → Triton deploy)
docs/SETUP.md — prerequisites (driver ≥ 570, CUDA 12.8, Docker, NGC key), step-by-step install, 3D Slicer plugin install
docs/LABELING.md — 3D Slicer workflow, OHIF workflow, active learning, saving labels, supported modalities (CT/MRI/X-ray/mammo)
docs/TRAINING.md — fine-tuning Zoo bundles via MONAI Label /train API, custom MONAI Core training scripts, TensorBoard monitoring
docs/INFERENCE.md — running inference via REST API, MONAI Deploy MAP packaging, Triton deployment, example cURL commands for tumor detection
docs/LLM_INTEGRATION.md — architecture for connecting MONAI inference output (structured findings JSON) to an LLM (local Ollama or OpenAI-compatible) for report generation
Verification

After running ./scripts/setup.sh && ./scripts/download-models.sh && ./scripts/start.sh:

curl http://localhost:8000/info → MONAI Label server info JSON
curl http://localhost:8042/app → Orthanc web UI
http://localhost:3000 in browser → OHIF Viewer
3D Slicer → MONAI Label plugin → connect to http://localhost:8000 → load a study → run brats_mri_segmentation
nvidia-smi shows GPU in use during inference
Decisions

Custom Dockerfile (CUDA 12.8) over stock projectmonai/monailabel:latest — RTX 5090 Blackwell requires sm_100 support only in CUDA 12.6+
monaibundle as default MONAI Label app — covers all modalities via Zoo, more flexible than hardcoded radiology app
Orthanc as DICOM server — open-source, DICOMweb-capable, well-supported; replaces need for PACS
OHIF as browser viewer — works without any client install; 3D Slicer remains optional for advanced interactive segmentation
Triton included but optional (gated behind .env flag) — needed for high-throughput production inference with MONAI Deploy MAPs
3D Slicer installed on host (not Docker) — it's a GUI app requiring X11 display; connecting to MONAI Label server over localhost:8000 is the standard supported workflow
datasets renamed from ct_data/<your_ct> → datasets/ct/ and mri_data/<your_mri> → datasets/mri/ for cleaner mount paths
Does this plan look right? A few quick confirmations before I hand it off for implementation:

Checked schema and updated "Triton Server" to "Triton"
Asked 4 questions (NGC Key, LLM Backend, X-ray / RTG, Triton)

Holoscan and Triton images are on NVIDIA NGC and require a free NGC API key (ngc.nvidia.com). Do you have an NGC account / API key?
Yes, I have an NGC key
For LLM integration (generating radiology reports from MONAI findings), which backend should scripts and docs target?
LM studio, self hosted, available at http://localhost:1234
MONAI Zoo has no dedicated X-ray pathology classifier yet. For chest X-ray / RTG detection, which approach should be included?
TorchXRayVision (14-pathology open-source)
Triton Inference Server adds production GPU model serving but needs NGC login and model conversion. How should it be handled?
Include, fully enabled
Refined and finalized plan with user decisions incorporated
All answers received. Here is the finalized plan incorporating your choices:

Plan: MONAI Medical Imaging AI Platform — Full Stack
TL;DR: Deploy a 6-service Docker Compose stack on Ubuntu with RTX 5090. A custom Dockerfile (CUDA 12.8 base) is required because the stock MONAI Label image predates Blackwell sm_100 support. Services: MONAI Label (annotation server), OHIF (browser DICOM viewer), Orthanc (DICOM store), Triton (GPU model serving, fully enabled), Holoscan (real-time inference engine), and a TorchXRayVision sidecar for RTG/CXR pathology (fills the MONAI Zoo gap). LLM integration targets LM Studio at localhost:1234 via its OpenAI-compatible API. 3D Slicer installed natively on the Ubuntu host, connecting to MONAI Label at localhost:8000. Shell scripts manage the full lifecycle. Full documentation covers everything from setup to tumor diagnosis.

Steps

1. Restructure the project tree

Rename and reorganize existing content:

<series> → datasets/ct/<series>/
<series> → datasets/mri/<series>/
Create: docker/, models/bundles/, models/triton/, scripts/, storage/orthanc-db/, storage/logs/, docs/
2. Custom Dockerfile — docker/monailabel/Dockerfile

Base: nvcr.io/nvidia/cuda:12.8.0-cudnn-devel-ubuntu22.04
Layer: Python 3.11 + pip install torch torchvision --index-url .../whl/cu128
Layer: pip install "monai[all]" monailabel monai-deploy-app-sdk torchxrayvision
Layer: copy apps and startup entrypoint
Result: single image serving MONAI Label + TorchXRayVision inference on RTX 5090

3. docker/docker-compose.yml — 6 services, all GPU-enabled

Service	Image	Ports	Purpose
monailabel	./docker/monailabel (custom)	8000	Annotation + Zoo inference server
ohif	ohif/app:latest	3000	Browser DICOM viewer
orthanc	orthancteam/orthanc:latest	8042 / 4242	DICOM store (DICOMweb)
triton	nvcr.io/nvidia/tritonserver:25.01-py3	8001/8002/8003	Production GPU model serving
holoscan	nvcr.io/nvidia/clara-holoscan/holoscan:v3.11.0-cuda12-dgpu	8008	Real-time streaming inference
tensorboard	tensorflow/tensorflow:latest	6006	Training monitoring
All services share a monai-platform Docker network. datasets, ./models, apps, ./storage mounted as bind volumes.

4. docker/.env — all tunable config in one file

Key vars: MONAILABEL_APP=monaibundle, MONAILABEL_MODELS=brats_mri_segmentation,lung_nodule_ct_detection,wholeBody_ct_segmentation,breast_density_classification,pathology_tumor_detection,vista3d, NGC_API_KEY=<your-key>, LLM_BASE_URL=http://localhost:1234, LLM_MODEL=<model-name>, MONAILABEL_PORT=8000

5. Orthanc config — docker/orthanc/orthanc.json

DICOMweb plugin enabled; AET=MONAI; CORS allowing OHIF at localhost:3000 and MONAI Label at localhost:8000; local storage at /var/lib/orthanc/db (→ ./storage/orthanc-db/)

6. OHIF config — docker/ohif/app-config.js

DataSource: Orthanc DICOMweb at http://localhost:8042/dicom-web; MONAI Label extension configured to http://localhost:8000

7. Triton model repository — models/triton/

Create standard Triton directory structure for exported MONAI Zoo models (ONNX/TorchScript). Include a conversion helper script so bundles downloaded from Zoo can be exported and registered with Triton.

8. Scripts — scripts/

scripts/setup.sh — check nvidia driver ≥ 570, Docker Compose v2, NGC login (docker login nvcr.io), create all directories, copy .env.example → .env
scripts/build.sh — docker compose build monailabel
scripts/download-models.sh — pull 8 Zoo bundles: brats_mri_segmentation, lung_nodule_ct_detection, wholeBody_ct_segmentation, breast_density_classification, pathology_tumor_detection, pathology_nuclei_segmentation_classification, vista3d, swin_unetr_btcv_segmentation; also download MONAI Label apps (radiology, monaibundle, pathology)
scripts/start.sh — docker compose up -d; poll health endpoints; print service table with URLs
scripts/stop.sh / scripts/restart.sh — compose down/restart with optional service name arg
scripts/status.sh — container health, GPU usage (nvidia-smi), port availability
scripts/logs.sh — docker compose logs -f [service] with color
scripts/switch-app.sh — update .env MONAILABEL_APP and restart just the monailabel container
scripts/install-slicer.sh — download 3D Slicer 5.x tarball to ~/slicer/, create desktop launcher, print MONAI Label plugin install instructions
scripts/run-inference.sh — example cURL wrapper: POST a DICOM to MONAI Label /infer/{model}, display JSON findings, optionally POST to LM Studio at localhost:1234 for report generation
9. LLM Integration — docs/LLM_INTEGRATION.md + helper script

MONAI Label returns structured JSON findings (labels, probability scores, bounding boxes). A small Python script (scripts/report-generator.py) calls LM Studio's OpenAI-compatible /v1/chat/completions endpoint, injecting finding metadata into a radiology report prompt template. Configurable via LLM_BASE_URL, LLM_MODEL in .env.

10. TorchXRayVision for RTG / Chest X-ray

Installed inside the custom MONAI Label image. A MONAI Label monaibundle-compatible wrapper will expose it at /infer/cxr_pathology. Detects 14 pathologies: Atelectasis, Cardiomegaly, Effusion, Infiltration, Mass, Nodule, Pneumonia, Pneumothorax, Consolidation, Edema, Emphysema, Fibrosis, Pleural Thickening, Hernia.

11. Documentation — docs/

docs/README.md — overview, 3-command quick-start, service URLs table, hardware requirements
docs/ARCHITECTURE.md — full component diagram (data flow: DICOM upload → Orthanc → MONAI Label → annotate → train → Triton/deploy → LLM report)
docs/SETUP.md — driver install, NGC key, Docker setup, ./scripts/setup.sh, ./scripts/build.sh, ./scripts/download-models.sh, ./scripts/start.sh, 3D Slicer plugin install
docs/LABELING.md — OHIF browser labeling, 3D Slicer interactive segmentation with DeepEdit/DeepGrow/VISTA-3D, active learning workflow, label export
docs/TRAINING.md — fine-tuning Zoo bundles via MONAI Label /train API, monitoring with TensorBoard at localhost:6006, custom MONAI Core scripts
docs/INFERENCE.md — REST API examples (cURL/Python) for each modality: brain tumor MRI, lung nodule CT, mammography density, RTG pathology, pathology WSI; MONAI Deploy MAP packaging for production; Triton serving
docs/LLM_INTEGRATION.md — connecting MONAI findings JSON to LM Studio (localhost:1234), prompt engineering for radiology reports, sample output
Verification

After the full setup:

./scripts/status.sh → all 6 containers healthy, GPU detected
curl http://localhost:8000/info → MONAI Label JSON with loaded models
curl http://localhost:8042/app → Orthanc web UI
http://localhost:3000 → OHIF Viewer with Orthanc data source
http://localhost:8000/docs → Swagger UI showing all MONAI Label endpoints
3D Slicer → MONAI Label plugin → http://localhost:8000 → load MRI/CT → run brats_mri_segmentation / lung_nodule_ct_detection
./scripts/run-inference.sh --model brats_mri_segmentation --dicom [datasets](http://_vscodecontentref_/8). → JSON findings + LLM report
Decisions (from your answers)

Custom CUDA 12.8 image instead of stock projectmonai/monailabel:latest — RTX 5090 Blackwell (sm_100) requires CUDA 12.8+
LLM: LM Studio at localhost:1234 via OpenAI-compatible API — .env configures URL and model name
X-ray/RTG: TorchXRayVision — bundled inside the custom MONAI Label image, exposed as a MONAI Label-compatible inference endpoint
Triton: fully enabled — NGC login required during setup; model export helper script included
3D Slicer on host (not Docker) — GUI requirement; standard supported approach per MONAI Label docs
Orthanc as DICOM store — open-source, DICOMweb-native, bridges OHIF and MONAI Label
Does this plan look good to proceed, or would you like to adjust anything (e.g., add Ollama alongside LM Studio, change any port, add more Zoo models, adjust the folder naming)?

Claude Sonnet 4.6 • 1x
