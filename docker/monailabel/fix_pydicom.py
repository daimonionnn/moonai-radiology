"""
Compatibility shim: pydicom-seg 0.4.1 uses pydicom._storage_sopclass_uids
which was removed in pydicom 3.0. This script creates the missing module
mapping SegmentationStorage to the correct UID.
"""
import os
import pydicom

shim_path = os.path.join(os.path.dirname(pydicom.__file__), "_storage_sopclass_uids.py")
if not os.path.exists(shim_path):
    with open(shim_path, "w") as f:
        # SegmentationStorage SOP Class UID (DICOM PS3.6 A.51)
        f.write('SegmentationStorage = "1.2.840.10008.5.1.4.1.1.66.4"\n')
    print("[fix_pydicom] Created pydicom/_storage_sopclass_uids.py compatibility shim")
else:
    print("[fix_pydicom] Compatibility shim already present")
