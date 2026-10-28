#!/bin/bash
# ============================================================
#  MOONAI — check which components have newer versions (read-only)
#
#  Compares installed versions with the latest releases and prints what can be
#  upgraded and how. Nothing is installed or changed.
#
#  Checked: 3D Slicer, Docker images (OHIF, Orthanc), the MONAI Label image's
#  MONAI / MONAI Label, host venvs (TotalSegmentator, nnU-Net, nnInteractive,
#  moonai), vesselFM (git), MONAI Model Zoo bundles.
#
#  Usage:  ./scripts/check-updates.sh
# ============================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PROJECT_ROOT

python3 - << 'PYEOF'
import json, os, re, subprocess, urllib.request
from pathlib import Path

ROOT = Path(os.environ["PROJECT_ROOT"]); HOME = Path.home()
GREEN, YELLOW, GREY, BOLD, NC = "\033[0;32m", "\033[1;33m", "\033[0;90m", "\033[1m", "\033[0m"
rows = []   # (component, installed, latest, status, how)


def get_json(url, timeout=20):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "moonai"}), timeout=timeout) as r:
            return json.load(r)
    except Exception:
        return None


def run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception:
        return ""


def vkey(v):
    return [int(x) if x.isdigit() else x for x in re.split(r"[.\-+]", re.sub(r"^v", "", v or ""))]


def add(name, installed, latest, how="", note=""):
    if not installed:
        status = "not installed"
    elif not latest:
        status = "unknown (offline?)"
    elif vkey(installed) >= vkey(latest):
        status = "up to date"
    else:
        status = "UPDATE"
    rows.append((name, installed or "-", latest or "-", status + (f" — {note}" if note else ""), how if status == "UPDATE" else ""))


def pypi_latest(pkg):
    d = get_json(f"https://pypi.org/pypi/{pkg}/json")
    return d["info"]["version"] if d else None


def venv_version(venv, pkg):
    py = HOME / ".venvs" / venv / "bin" / "python"
    if not py.exists():
        return None
    return run(str(py), "-c", f"import importlib.metadata as m; print(m.version('{pkg}'))") or None


# ── 3D Slicer ─────────────────────────────────────────────────
cur = HOME / "slicer" / "current"
inst = None
if cur.exists():
    m = re.search(r"Slicer-(.+)-linux-amd64", os.path.realpath(cur))
    inst = m.group(1) if m else None
else:
    vs = sorted((p.name for p in (HOME / "slicer").glob("Slicer-*-linux-amd64")), key=vkey)
    inst = re.search(r"Slicer-(.+)-linux-amd64", vs[-1]).group(1) if vs else None
d = get_json("https://download.slicer.org/find?os=linux&stability=release")
add("3D Slicer", inst, d and d.get("version"), "./scripts/install-slicer.sh  (then ./scripts/oncology/setup-slicer.sh)")

# ── Docker images ─────────────────────────────────────────────
compose = (ROOT / "docker" / "docker-compose.yml").read_text()
m = re.search(r"image:\s*ohif/app:(v[\d.]+)", compose)
tags = get_json("https://hub.docker.com/v2/repositories/ohif/app/tags?page_size=100&ordering=last_updated")
ohif_latest = None
if tags:
    stable = [t["name"] for t in tags["results"] if re.fullmatch(r"v\d+\.\d+\.\d+", t["name"])]
    ohif_latest = max(stable, key=vkey) if stable else None
add("OHIF viewer (image)", m and m.group(1), ohif_latest,
    "edit ohif/app:<tag> in docker/docker-compose*.yml, test, ./scripts/restart.sh", "test the config before switching")

local = run("docker", "image", "inspect", "orthancteam/orthanc:latest", "--format", "{{.Created}}")[:10]
tags = get_json("https://hub.docker.com/v2/repositories/orthancteam/orthanc/tags/latest")
remote = tags and tags.get("last_updated", "")[:10]
rows.append(("Orthanc (image :latest)", local or "-", remote or "-",
             ("UPDATE" if local and remote and remote > local else "up to date") if local else "not pulled",
             "docker pull orthancteam/orthanc:latest && ./scripts/restart.sh" if local and remote and remote > local else ""))

# ── MONAI Label image ─────────────────────────────────────────
for pkg in ("monai", "monailabel"):
    v = run("docker", "run", "--rm", "--entrypoint", "python3", "monai-platform/monailabel:latest", "-c",
            f"import importlib.metadata as m; print(m.version('{pkg}'))").splitlines()
    v = v[-1].split("+")[0] if v else None
    add(f"{pkg} (MONAI Label image)", v, pypi_latest(pkg),
        "edit MONAI_VERSION in docker/monailabel/Dockerfile, ./scripts/build.sh, run the regression tests",
        "check the Spacingd patch in the Dockerfile" if pkg == "monai" else "")

# ── Host Python environments ──────────────────────────────────
for venv, pkg, how in (("totalseg", "TotalSegmentator", "VIRTUAL_ENV=~/.venvs/totalseg uv pip install -U TotalSegmentator"),
                       ("totalseg", "nnunetv2", "VIRTUAL_ENV=~/.venvs/totalseg uv pip install -U nnunetv2"),
                       ("nninteractive", "nninteractive", "VIRTUAL_ENV=~/.venvs/nninteractive uv pip install -U nninteractive"),
                       ("moonai", "pydicom", "./scripts/setup-python.sh"),
                       ("moonai", "SimpleITK", "./scripts/setup-python.sh")):
    add(f"{pkg} (~/.venvs/{venv})", venv_version(venv, pkg), pypi_latest(pkg), how)

# ── vesselFM (git checkout) ───────────────────────────────────
vfm = HOME / "tools" / "vesselFM"
if (vfm / ".git").exists():
    run("git", "-C", str(vfm), "fetch", "-q")
    behind = run("git", "-C", str(vfm), "rev-list", "--count", "HEAD..@{u}")
    head = run("git", "-C", str(vfm), "log", "-1", "--format=%h %cd", "--date=short")
    rows.append(("vesselFM (git)", head, f"{behind or '?'} commit(s) behind",
                 "UPDATE" if behind and behind != "0" else "up to date",
                 "git -C ~/tools/vesselFM pull" if behind and behind != "0" else ""))

# ── MONAI Model Zoo bundles ───────────────────────────────────
# A newer bundle may require a newer MONAI than the image has — then it is not offered.
img_monai = next((r[1] for r in rows if r[0].startswith("monai (")), None)
# released versions (what download-models.sh fetches) — the dev branch is ahead of them
index = get_json("https://raw.githubusercontent.com/Project-MONAI/model-zoo/dev/models/model_info.json") or {}
released = {}
for k in index:
    m = re.match(r"(.+)_v([\d.]+)$", k)
    if m and (m.group(1) not in released or vkey(m.group(2)) > vkey(released[m.group(1)])):
        released[m.group(1)] = m.group(2)
for meta in sorted((ROOT / "models" / "bundles").glob("*/configs/metadata.json")):
    name = meta.parent.parent.name
    inst = json.loads(meta.read_text()).get("version")
    zoo = get_json(f"https://raw.githubusercontent.com/Project-MONAI/model-zoo/dev/models/{name}/configs/metadata.json")
    latest = released.get(name)
    dev = zoo and zoo.get("version")
    if latest and dev and vkey(dev) > vkey(latest) and vkey(inst) >= vkey(latest):
        rows.append((f"bundle {name}", inst, latest, f"up to date (dev branch has {dev}, not released)", ""))
        continue
    note = ""
    needs = zoo and zoo.get("monai_version")
    if zoo and latest and vkey(inst) < vkey(latest) and img_monai and needs and vkey(needs) > vkey(img_monai):
        rows.append((f"bundle {name}", inst, latest, f"newer needs MONAI {needs} (image has {img_monai}) — keep", ""))
        continue
    if zoo and latest and vkey(inst) < vkey(latest):
        log = zoo.get("changelog", {})
        newer = [f"{k}: {v}" for k, v in log.items() if vkey(k) > vkey(inst)]
        note = "; ".join(newer[:2])[:110]
    add(f"bundle {name}", inst, latest,
        f"rm -rf models/bundles/{name} && ./scripts/download-models.sh --bundle {name} && ./scripts/restart.sh", note)

# ── Print ─────────────────────────────────────────────────────
w = max(len(r[0]) for r in rows)
print(f"\n{BOLD}{'Component':<{w}}  {'Installed':<22} {'Latest':<22} Status{NC}")
for name, inst, latest, status, how in rows:
    col = YELLOW if status.startswith("UPDATE") else (GREY if any(w in status for w in ("unknown", "not", "keep")) else GREEN)
    print(f"{name:<{w}}  {str(inst):<22} {str(latest):<22} {col}{status}{NC}")
ups = [(n, h) for n, _, _, s, h in rows if s.startswith("UPDATE") and h]
if ups:
    print(f"\n{BOLD}How to update{NC}")
    for n, h in ups:
        print(f"  {n:<{w}}  {h}")
print(f"\n{GREY}Nothing was changed. Re-test after upgrading (docs/research/PUBLIC_DATA_TESTS.md).{NC}")
PYEOF
