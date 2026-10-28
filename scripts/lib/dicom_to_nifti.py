#!/usr/bin/env python3
"""
Convert ONE DICOM series to NIfTI:  python dicom_to_nifti.py <dicom_dir> <out.nii.gz>

A study folder often holds several series (scout, native, arterial, venous…) in
subfolders; converting them together fails with "MISSING_DICOM_FILES". If the
folder (recursively) contains more than one series, list them with descriptions and
the path to pass instead, and exit with code 2.
"""
import os
import sys

import pydicom


def series_in(root: str) -> dict:
    found = {}
    for d, _, files in os.walk(root):
        for f in sorted(files):
            try:
                ds = pydicom.dcmread(os.path.join(d, f), stop_before_pixels=True)
            except Exception:
                continue
            uid = getattr(ds, "SeriesInstanceUID", None)
            if not uid:
                continue
            s = found.setdefault(uid, {"dirs": set(), "files": 0,
                                       "desc": str(getattr(ds, "SeriesDescription", "")),
                                       "modality": str(getattr(ds, "Modality", ""))})
            s["dirs"].add(d)
            s["files"] += 1
    return found


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    series = series_in(src)
    if not series:
        print(f"No DICOM files found in {src}", file=sys.stderr)
        return 1
    if len(series) > 1:
        print(f"{src} contains {len(series)} series — pass ONE of these folders as --image:",
              file=sys.stderr)
        for s in sorted(series.values(), key=lambda s: sorted(s["dirs"])[0]):
            where = sorted(s["dirs"])[0] if len(s["dirs"]) == 1 else f"{src} (mixed folder)"
            print(f"  {s['modality']:3s} {s['files']:4d} images  {s['desc']:<32s} {where}", file=sys.stderr)
        return 2
    import dicom2nifti
    dicom2nifti.dicom_series_to_nifti(src, dst, reorient_nifti=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
