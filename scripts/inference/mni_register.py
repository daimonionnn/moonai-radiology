#!/usr/bin/env python3
"""
Affine registration of a T1w brain MRI to the MNI305 template.

Some MONAI Zoo bundles (wholeBrainSeg_Large_UNEST_segmentation) were trained on
T1 images affinely registered to MNI305 and give meaningless volumes on native
images. run-inference.sh calls this before uploading such a model's input:

    python mni_register.py <native.nii.gz> <registered.nii.gz>

It prints one JSON line: {"volume_scale": s, "transform": "<file>.tfm", ...}.
A region of volume V in MNI space corresponds to s·V in the native image
(s = |det A| of the affine that maps template points into the native image), so
volumes measured on the MNI-space mask are multiplied by s to be in native mL.

Template: MNI305 from TemplateFlow, downloaded once to models/templates/MNI305/
(McGill licence: free use with copyright notice; see LICENSE there).
"""
import json
import os
import sys
import urllib.request

import numpy as np
import SimpleITK as sitk

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEMPLATE_DIR = os.path.join(PROJECT_ROOT, "models", "templates", "MNI305")
TEMPLATE_URL = "https://templateflow.s3.amazonaws.com/tpl-MNI305/"
TEMPLATE_FILES = ("tpl-MNI305_T1w.nii.gz", "LICENSE")


def template_path() -> str:
    os.makedirs(TEMPLATE_DIR, exist_ok=True)
    for name in TEMPLATE_FILES:
        dst = os.path.join(TEMPLATE_DIR, name)
        if not os.path.exists(dst):
            print(f"[mni] downloading {name} from TemplateFlow", file=sys.stderr)
            urllib.request.urlretrieve(TEMPLATE_URL + name, dst)
    return os.path.join(TEMPLATE_DIR, TEMPLATE_FILES[0])


def register(native_path: str, out_path: str) -> dict:
    fixed = sitk.ReadImage(template_path(), sitk.sitkFloat32)
    moving = sitk.ReadImage(native_path, sitk.sitkFloat32)

    init = sitk.CenteredTransformInitializer(
        fixed, moving, sitk.AffineTransform(3), sitk.CenteredTransformInitializerFilter.MOMENTS)

    reg = sitk.ImageRegistrationMethod()
    reg.SetMetricAsMattesMutualInformation(numberOfHistogramBins=50)
    reg.SetMetricSamplingStrategy(reg.RANDOM)
    reg.SetMetricSamplingPercentage(0.05, seed=42)
    reg.SetInterpolator(sitk.sitkLinear)
    reg.SetOptimizerAsRegularStepGradientDescent(
        learningRate=1.0, minStep=1e-4, numberOfIterations=300, relaxationFactor=0.6)
    reg.SetOptimizerScalesFromPhysicalShift()
    reg.SetShrinkFactorsPerLevel([4, 2, 1])
    reg.SetSmoothingSigmasPerLevel([2, 1, 0])
    reg.SmoothingSigmasAreSpecifiedInPhysicalUnitsOn()
    affine = sitk.AffineTransform(init)
    reg.SetInitialTransform(affine, inPlace=True)
    reg.Execute(fixed, moving)
    metric = reg.GetMetricValue()

    registered = sitk.Resample(moving, fixed, affine, sitk.sitkLinear, 0.0, sitk.sitkFloat32)
    sitk.WriteImage(registered, out_path)
    tfm = out_path.replace(".nii.gz", "").replace(".nii", "") + "_to_native.tfm"
    sitk.WriteTransform(affine, tfm)

    A = np.array(affine.GetMatrix()).reshape(3, 3)
    scale = float(abs(np.linalg.det(A)))
    return {"volume_scale": round(scale, 5), "transform": tfm, "metric": round(metric, 4),
            "template": "MNI305 (TemplateFlow)"}


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    print(json.dumps(register(sys.argv[1], sys.argv[2])))
