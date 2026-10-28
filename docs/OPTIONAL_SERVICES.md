# Optional services: Triton & Holoscan

Triton and Holoscan were **removed from the default stack** because they are not
needed for this project's workflow (batch analysis of stored DICOM studies):

- **Triton Inference Server** — production model *serving* at scale (TensorRT,
  high concurrency). MONAI Label already runs inference itself, so Triton is only
  useful once you want a dedicated production serving layer.
- **Holoscan** — *real-time streaming* inference from live devices (endoscopy,
  ultrasound, surgical video). Irrelevant for stored-study radiology, and its
  image requires an NGC login.

Removing them also means **no NGC API key is required** for normal use.

If you later need either service, follow the steps below to bring it back.

---

## 1. NGC API key (needed for Holoscan; Triton usually pulls without it)

1. Create a free key: https://ngc.nvidia.com → Setup → Generate API Key
2. Put it in `docker/.env` (which is git-ignored — never commit it):
   ```ini
   NGC_API_KEY=nvapi-xxxxxxxx
   ```
3. Log Docker into the NGC registry:
   ```bash
   echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin
   ```

Re-add these port variables to `docker/.env` (and `.env.example`):
```ini
TRITON_HTTP_PORT=8010
TRITON_GRPC_PORT=8001
TRITON_METRICS_PORT=8002
HOLOSCAN_PORT=8008
```

---

## 2. Add the services back to `docker/docker-compose.yml`

Paste these blocks under `services:` (they reuse the existing `x-gpu`/`*gpu`
anchor and `monai-network`, both still present in the compose file).

### Triton Inference Server
```yaml
  triton:
    image: nvcr.io/nvidia/tritonserver:25.01-py3
    container_name: triton
    hostname: triton
    restart: unless-stopped
    <<: *gpu
    ports:
      - "${TRITON_HTTP_PORT:-8010}:8000"
      - "${TRITON_GRPC_PORT:-8001}:8001"
      - "${TRITON_METRICS_PORT:-8002}:8002"
    volumes:
      - ${HOST_MODELS_PATH:-../models}/triton:/models
    command: >
      tritonserver
        --model-repository=/models
        --model-control-mode=poll
        --repository-poll-secs=30
        --log-verbose=1
        --allow-metrics=true
        --allow-gpu-metrics=true
    networks:
      - monai-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/v2/health/ready"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
```

Export a MONAI bundle to the Triton model repository with the existing helper:
```bash
python scripts/export_to_triton.py
```

### Holoscan (real-time streaming)
```yaml
  holoscan:
    image: nvcr.io/nvidia/clara-holoscan/holoscan:v3.11.0-cuda12-dgpu
    container_name: holoscan
    hostname: holoscan
    restart: unless-stopped
    <<: *gpu
    ports:
      - "${HOLOSCAN_PORT:-8008}:8008"
    volumes:
      - ${HOST_MODELS_PATH:-../models}/bundles:/workspace/bundles
      - ${HOST_DATASETS_PATH:-../datasets}:/workspace/datasets
      - ${HOST_STORAGE_PATH:-../storage}/logs:/workspace/logs
    ipc: host
    cap_add:
      - SYS_PTRACE
    ulimits:
      memlock: -1
      stack: 67108864
    command: sleep infinity   # keep alive; use `docker exec -it holoscan bash`
    networks:
      - monai-network
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "3"
```

---

## 3. Start them

```bash
# after logging into nvcr.io and adding the blocks above
docker compose -f docker/docker-compose.yml --env-file docker/.env up -d triton holoscan
```

> Note: both need an NVIDIA GPU + `nvidia-container-toolkit`. Holoscan's image is
> ~10 GB. Neither runs in the CPU-only compose (`docker-compose.cpu.yml`).
