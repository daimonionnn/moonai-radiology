#!/bin/bash
# ============================================================
#  MONAI Platform — Install 3D Slicer + MONAI Label Plugin
#
#  Downloads and installs 3D Slicer (an open-source medical
#  image viewer and analysis platform) to ~/slicer/.  Creates
#  both a desktop launcher (GNOME/KDE) and a shell command
#  (slicer3d) for convenient access.
#
#  3D Slicer integrates with MONAI Label via its MONAILabel
#  extension, allowing interactive AI-assisted segmentation
#  directly in the viewer.  Installation instructions for the
#  plugin are printed at the end.
#
#  Usage:  ./scripts/install-slicer.sh
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SLICER_DIR="${HOME}/slicer"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

SLICER_VERSION="5.10.0"
SLICER_TARBALL="Slicer-${SLICER_VERSION}-linux-amd64.tar.gz"
# Use download.slicer.org API — redirects to the correct bitstream for the version
SLICER_DOWNLOAD_URL="https://download.slicer.org/download?version=5.10&os=linux&stability=release"

header "Installing 3D Slicer ${SLICER_VERSION}"

mkdir -p "$SLICER_DIR"

if [ -d "${SLICER_DIR}/Slicer-${SLICER_VERSION}-linux-amd64" ]; then
    ok "3D Slicer ${SLICER_VERSION} already installed at ${SLICER_DIR}"
else
    # Remove any previous zero-byte or incomplete download
    rm -f "${SLICER_DIR}/${SLICER_TARBALL}"

    info "Downloading 3D Slicer ${SLICER_VERSION}..."
    info "Source: ${SLICER_DOWNLOAD_URL}"
    info "Target: ${SLICER_DIR}/${SLICER_TARBALL}"
    info "This is ~1 GB — grab a coffee ☕"

    if ! wget -q --show-progress --content-disposition -L \
        -O "${SLICER_DIR}/${SLICER_TARBALL}" \
        "${SLICER_DOWNLOAD_URL}"; then
        warn "Download failed. Please download manually from https://download.slicer.org"
        rm -f "${SLICER_DIR}/${SLICER_TARBALL}"
        exit 1
    fi

    # Verify tarball is not empty
    TARBALL_SIZE=$(stat -c%s "${SLICER_DIR}/${SLICER_TARBALL}" 2>/dev/null || echo 0)
    if [ "$TARBALL_SIZE" -lt 100000000 ] 2>/dev/null; then
        warn "Downloaded file seems too small (${TARBALL_SIZE} bytes) — download may have failed"
        rm -f "${SLICER_DIR}/${SLICER_TARBALL}"
        exit 1
    fi

    info "Extracting (~1 GB, please wait)..."
    tar -xzf "${SLICER_DIR}/${SLICER_TARBALL}" -C "${SLICER_DIR}"
    rm -f "${SLICER_DIR}/${SLICER_TARBALL}"
    ok "3D Slicer extracted to: ${SLICER_DIR}/Slicer-${SLICER_VERSION}-linux-amd64"
fi

SLICER_BIN="${SLICER_DIR}/Slicer-${SLICER_VERSION}-linux-amd64/Slicer"

# ── System libraries Slicer needs but does not bundle ─────────
# Without libGLU, Slicer exits immediately with
# "libGLU.so.1: cannot open shared object file".
header "Checking system libraries"
if ldconfig -p | grep -q "libGLU.so.1"; then
    ok "libGLU present"
else
    info "Installing libglu1-mesa (requires sudo)..."
    if sudo apt-get install -y libglu1-mesa; then
        ok "libglu1-mesa installed"
    else
        warn "Could not install libglu1-mesa — run: sudo apt install libglu1-mesa"
    fi
fi

# ── Desktop launcher ──────────────────────────────────────────
header "Creating desktop launcher"
DESKTOP_FILE="${HOME}/.local/share/applications/slicer.desktop"
mkdir -p "${HOME}/.local/share/applications"
cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=3D Slicer ${SLICER_VERSION}
Comment=Medical Image Visualization and Analysis
Exec=${SLICER_BIN}
Icon=${SLICER_DIR}/Slicer-${SLICER_VERSION}-linux-amd64/slicer.png
Terminal=false
Categories=Science;
EOF
chmod +x "$DESKTOP_FILE"
ok "Desktop launcher created: $DESKTOP_FILE"

# ── Shell launcher ────────────────────────────────────────────
LAUNCHER="/usr/local/bin/slicer3d"
sudo bash -c "cat > ${LAUNCHER} << 'EOF'
#!/bin/bash
exec ${SLICER_BIN} \"\$@\"
EOF
chmod +x ${LAUNCHER}" 2>/dev/null && ok "Created /usr/local/bin/slicer3d launcher" || \
warn "Could not create /usr/local/bin/slicer3d (no sudo). Run Slicer directly: ${SLICER_BIN}"

# ── MONAI Label plugin install instructions ──────────────────
header "MONAI Label Plugin for 3D Slicer"
echo ""
echo -e "${BOLD}Option A — Extension Manager (recommended):${NC}"
echo "  1. Open 3D Slicer"
echo "  2. View → Extension Manager"
echo "  3. Search for: MONAI Label"
echo "  4. Click Install, then restart Slicer"
echo ""
echo -e "${BOLD}Option B — Manual install:${NC}"
echo "  git clone https://github.com/Project-MONAI/MONAILabel.git ~/MONAILabel"
echo "  In Slicer: Edit → Application Settings → Modules → Additional Module Paths"
echo "  Add path: ~/MONAILabel/plugins/slicer/MONAILabel"
echo "  Restart Slicer"
echo ""
echo -e "${BOLD}Connect to MONAI Label server:${NC}"
echo "  1. Open MONAI Label module in Slicer (search in module finder)"
echo "  2. Server: http://localhost:8000"
echo "  3. Click: Next Sample → the module loads a DICOM/NIfTI study"
echo "  4. In 'Active Learning' select a model"
echo "     e.g. wholeBrainSeg_Large_UNEST_segmentation (brain MRI, single T1 series)"
echo "     e.g. wholeBody_ct_segmentation (CT, 104 structures)"
echo "  5. Click Run → AI segmentation appears as a label map"
echo "  6. Edit in Segment Editor if needed"
echo "  7. Click Submit → label saved to MONAI Label datastore"
echo ""
echo -e "${CYAN}Launch Slicer:${NC}  slicer3d  OR  ${SLICER_BIN}"
echo ""
ok "Installation complete"
