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
#  Usage:  ./scripts/install-slicer.sh             (install or upgrade to latest stable)
#          SLICER_VERSION=5.10 ./scripts/install-slicer.sh   (a specific release)
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

# Latest stable release from download.slicer.org (override: SLICER_VERSION=5.10 …).
# Re-running the script upgrades to a newer release; older versions are kept in
# ~/slicer/ and can be deleted by hand. Extensions must be reinstalled per version.
QUERY="os=linux&stability=release"
[ -n "${SLICER_VERSION:-}" ] && QUERY="${QUERY}&version=${SLICER_VERSION}"
META=$(curl -sf -m 30 "https://download.slicer.org/find?${QUERY}") \
    || { warn "Cannot reach download.slicer.org"; exit 1; }
read -r SLICER_VERSION DOWNLOAD_PATH SHA512 < <(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['version'], d['download_url'], d.get('sha512') or '-')" <<< "$META")
SLICER_TARBALL="Slicer-${SLICER_VERSION}-linux-amd64.tar.gz"
SLICER_DOWNLOAD_URL="https://download.slicer.org${DOWNLOAD_PATH}"

INSTALLED=$(ls -d "${SLICER_DIR}"/Slicer-*-linux-amd64 2>/dev/null | sed -E 's#.*/Slicer-(.*)-linux-amd64#\1#' | sort -V | tail -1)
header "Installing 3D Slicer ${SLICER_VERSION}${INSTALLED:+ (installed: ${INSTALLED})}"

mkdir -p "$SLICER_DIR"

if [ -d "${SLICER_DIR}/Slicer-${SLICER_VERSION}-linux-amd64" ]; then
    ok "3D Slicer ${SLICER_VERSION} (latest) already installed at ${SLICER_DIR}"
else
    rm -f "${SLICER_DIR}/${SLICER_TARBALL}"
    info "Downloading 3D Slicer ${SLICER_VERSION} (~0.5 GB)..."
    if ! wget -q --show-progress -L -O "${SLICER_DIR}/${SLICER_TARBALL}" "${SLICER_DOWNLOAD_URL}"; then
        warn "Download failed. Please download manually from https://download.slicer.org"
        rm -f "${SLICER_DIR}/${SLICER_TARBALL}"
        exit 1
    fi
    if [ "$SHA512" != "-" ]; then
        echo "${SHA512}  ${SLICER_DIR}/${SLICER_TARBALL}" | sha512sum -c --quiet \
            || { warn "Checksum mismatch — download corrupted"; rm -f "${SLICER_DIR}/${SLICER_TARBALL}"; exit 1; }
        ok "Checksum verified"
    fi
    info "Extracting..."
    tar -xzf "${SLICER_DIR}/${SLICER_TARBALL}" -C "${SLICER_DIR}"
    rm -f "${SLICER_DIR}/${SLICER_TARBALL}"
    ok "3D Slicer extracted to: ${SLICER_DIR}/Slicer-${SLICER_VERSION}-linux-amd64"
    [ -n "$INSTALLED" ] && info "Previous version ${INSTALLED} kept in ${SLICER_DIR} — delete it when no longer needed."
fi

# ~/slicer/current → newest installed version; launchers use it, so later upgrades
# need no sudo and no launcher changes.
ln -sfn "Slicer-${SLICER_VERSION}-linux-amd64" "${SLICER_DIR}/current"
SLICER_BIN="${SLICER_DIR}/current/Slicer"

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
Name=3D Slicer
Comment=Medical Image Visualization and Analysis
Exec=${SLICER_BIN}
Icon=${SLICER_DIR}/current/slicer.png
Terminal=false
Categories=Science;
EOF
chmod +x "$DESKTOP_FILE"
ok "Desktop launcher created: $DESKTOP_FILE"

# ── Shell launcher ────────────────────────────────────────────
LAUNCHER="/usr/local/bin/slicer3d"
if [ -f "$LAUNCHER" ] && grep -q "${SLICER_BIN}" "$LAUNCHER"; then
    ok "slicer3d launcher already points to ${SLICER_BIN}"
else
sudo bash -c "cat > ${LAUNCHER} << 'EOF'
#!/bin/bash
exec ${SLICER_BIN} \"\$@\"
EOF
chmod +x ${LAUNCHER}" 2>/dev/null && ok "Created /usr/local/bin/slicer3d launcher" || \
warn "Could not create /usr/local/bin/slicer3d (no sudo). Run Slicer directly: ${SLICER_BIN}"
fi

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
