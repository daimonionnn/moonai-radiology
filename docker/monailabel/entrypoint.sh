#!/bin/bash
# ============================================================
#  MONAI Label Container Entrypoint
#  Handles app-download, model-download, and server startup
# ============================================================
set -e

STUDIES_PATH="${MONAILABEL_STUDIES_LOCAL_PATH:-/workspace/datasets}"
APP="${MONAILABEL_APP:-monaibundle}"
MODELS="${MONAILABEL_MODELS:-brats_mri_segmentation}"
PRELOAD="${MONAILABEL_PRELOAD:-true}"
LOG_LEVEL="${MONAILABEL_LOG_LEVEL:-INFO}"
MODE="${MONAILABEL_STUDIES_MODE:-local}"

echo "=================================================="
echo "  MONAI Label Server — Starting Up"
echo "  App:     $APP"
echo "  Models:  $MODELS"
echo "  Mode:    $MODE"
echo "=================================================="

# ── Download app if not present ──────────────────────────────
APP_DIR="/workspace/apps/${APP}"
if [ ! -d "$APP_DIR" ]; then
    echo "[INFO] Downloading MONAI Label app: $APP"
    monailabel apps --download --name "$APP" --output /workspace/apps
else
    echo "[INFO] App already present: $APP_DIR"
fi

# ── Resolve studies path ─────────────────────────────────────
if [ "$MODE" = "dicomweb" ]; then
    STUDIES="http://orthanc:8042/dicom-web"
    echo "[INFO] Using DICOMweb datastore: $STUDIES"
else
    STUDIES="$STUDIES_PATH"
    echo "[INFO] Using local datastore: $STUDIES"
fi

# ── Build conf string ────────────────────────────────────────
CONF_ARGS="--conf models ${MODELS}"
if [ "$PRELOAD" = "true" ]; then
    CONF_ARGS="$CONF_ARGS --conf preload true"
fi

# ── Sync pre-downloaded bundles into app model dir ───────────
# download-models.sh puts bundles in /workspace/bundles (host: models/bundles/)
# MONAI Label's monaibundle app looks in {app_dir}/model/ (hardcoded, no config override)
# Copy bundles that are missing OR whose version / configs differ, so an
# updated bundle in models/bundles/ actually replaces the app's copy — previously only
# missing ones were copied and updates were silently ignored.
MODEL_DIR="${APP_DIR}/model"
mkdir -p "$MODEL_DIR"
# version + checksum of configs/, so a locally patched config (same version) also syncs
bundle_version() {
    [ -d "$1/configs" ] || return 0
    echo "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$1/configs/metadata.json" 2>/dev/null)" \
         "$(cat "$1"/configs/* 2>/dev/null | md5sum | cut -c1-8)"
}
if [ -d "/workspace/bundles" ] && [ "$(ls -A /workspace/bundles 2>/dev/null)" ]; then
    echo "[INFO] Syncing bundles: /workspace/bundles → ${MODEL_DIR}"
    for b in /workspace/bundles/*/; do
        name=$(basename "$b")
        target="${MODEL_DIR}/${name}"
        src_v=$(bundle_version "$b"); dst_v=$(bundle_version "$target")
        if [ ! -d "$target" ] || [ "$src_v" != "$dst_v" ]; then
            rm -rf "$target"
            cp -r "$b" "$target"
            echo "[INFO]   Synced: $name ${dst_v:+$dst_v → }$src_v"
        fi
    done
fi

# ── Start server ─────────────────────────────────────────────
echo "[INFO] Starting MONAI Label server on :8000 ..."
exec monailabel start_server \
    --app "$APP_DIR" \
    --studies "$STUDIES" \
    $CONF_ARGS \
    --log_level "$LOG_LEVEL" \
    --host 0.0.0.0 \
    --port 8000
