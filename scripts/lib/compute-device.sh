# shellcheck shell=bash
# Sourced by the platform and analysis scripts. Resolves where models run:
#   MOONAI_DEVICE in docker/.env = gpu | cpu | auto (default auto)
#   auto → gpu when an NVIDIA GPU is visible (nvidia-smi) AND Docker has the
#          NVIDIA runtime; otherwise cpu.
# Sets: MOONAI_DEVICE_RESOLVED (gpu|cpu) and COMPOSE_FILE (GPU or CPU compose).
# Expects PROJECT_ROOT to be set by the caller.

_moonai_env="${PROJECT_ROOT}/docker/.env"
_moonai_mode="${MOONAI_DEVICE:-}"
if [ -z "$_moonai_mode" ] && [ -f "$_moonai_env" ]; then
    _moonai_mode=$(grep -E '^MOONAI_DEVICE=' "$_moonai_env" | tail -1 | cut -d= -f2- | tr -d ' "' )
fi
_moonai_mode="${_moonai_mode:-auto}"

moonai_has_gpu() {
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

case "$_moonai_mode" in
    gpu|cpu) MOONAI_DEVICE_RESOLVED="$_moonai_mode" ;;
    auto|*)
        if moonai_has_gpu && docker info 2>/dev/null | grep -qi "runtimes.*nvidia"; then
            MOONAI_DEVICE_RESOLVED=gpu
        else
            MOONAI_DEVICE_RESOLVED=cpu
        fi ;;
esac

if [ "$MOONAI_DEVICE_RESOLVED" = cpu ]; then
    COMPOSE_FILE="${PROJECT_ROOT}/docker/docker-compose.cpu.yml"
else
    COMPOSE_FILE="${PROJECT_ROOT}/docker/docker-compose.yml"
fi
export MOONAI_DEVICE_RESOLVED
unset _moonai_env _moonai_mode

# MONAI Zoo bundles that hard-code a CUDA device in their network definition:
# on CPU they fail to instantiate and MONAI Label then refuses to start at all.
MOONAI_CUDA_ONLY_BUNDLES="pancreas_ct_dints_segmentation"

# In CPU mode, export MONAILABEL_MODELS without the CUDA-only bundles (the shell
# environment takes precedence over docker/.env when compose interpolates it).
moonai_filter_models_for_cpu() {
    [ "$MOONAI_DEVICE_RESOLVED" = cpu ] || return 0
    local models dropped="" kept="" m
    models=$(grep -E '^MONAILABEL_MODELS=' "${PROJECT_ROOT}/docker/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$models" ] || return 0
    for m in ${models//,/ }; do
        if [[ " $MOONAI_CUDA_ONLY_BUNDLES " == *" $m "* ]]; then dropped+="$m "; else kept+="${kept:+,}$m"; fi
    done
    export MONAILABEL_MODELS="$kept"
    [ -n "$dropped" ] && echo -e "\033[1;33m[WARN]\033[0m  CPU mode: skipping GPU-only model(s): ${dropped}"
    return 0
}
