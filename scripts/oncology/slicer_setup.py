# 3D Slicer setup script — run via ./scripts/oncology/setup-slicer.sh
# Installs the extensions MOONAI uses and points nnInteractive at the local server.
import os

import qt
import slicer

EXTENSIONS = ("NNInteractive", "SlicerVMTK", "MONAILabel", "TotalSegmentator")
server = os.environ.get("NNINTERACTIVE_URL", "http://localhost:1527")

em = slicer.app.extensionsManagerModel()
em.interactive = False
restart_needed = False
for name in EXTENSIONS:
    if em.isExtensionInstalled(name):
        print(f"[OK] extension {name} already installed")
        continue
    ok = em.downloadAndInstallExtensionByName(name, True, True)
    print(f"[{'OK' if ok else 'FAIL'}] extension {name} installed")
    restart_needed |= bool(ok)

# nnInteractive in Remote mode: Slicer only needs the torch-free client; the model runs
# in ./scripts/oncology/nninteractive-server.sh (keeps PyTorch out of Slicer's Python).
try:
    import nnInteractive  # noqa: F401
    print("[OK] nninteractive-client already in Slicer's Python")
except ImportError:
    slicer.util.pip_install("nninteractive-client>=2.6 scikit-image")
    print("[OK] nninteractive-client installed in Slicer's Python")

s = qt.QSettings()
s.setValue("SlicerNNInteractive/install_flavor", "client")
s.setValue("SlicerNNInteractive/mode", "remote")
s.setValue("SlicerNNInteractive/server", server.rstrip("/"))
s.sync()
print(f"[OK] nnInteractive: Remote mode, server {server}")
if restart_needed:
    print("[INFO] restart Slicer to load newly installed extensions")
slicer.app.exit(0)
