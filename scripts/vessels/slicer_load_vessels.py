# 3D Slicer startup script — loads a run-vessel-analysis.sh output folder.
# Run via:  ./scripts/vessels/open-vessels-in-slicer.sh <run_dir>
import os
import sys

import ctk
import slicer

run = os.environ.get("VESSEL_RUN_DIR") or (sys.argv[1] if len(sys.argv) > 1 else "")
if not os.path.isdir(run):
    slicer.util.errorDisplay(f"Run folder not found: {run!r}")
    raise SystemExit

p = lambda name: os.path.join(run, name)  # noqa: E731

# Original CT in the slice views, bone/bowel-removed CT for volume rendering
ct = slicer.util.loadVolume(p("arterial.nii.gz"), {"name": "CT arterial"})
clean = slicer.util.loadVolume(p("arterial_bone_bowel_removed.nii.gz"),
                               {"name": "CT bone+bowel removed", "show": False})
slicer.util.setSliceViewerLayers(background=ct, fit=True)


def set_ct_angio_window():
    # Auto window/level is on by default and is recomputed after loading, which
    # overrode a plain SetWindowLevel (slices looked washed-out grey).
    d = ct.GetDisplayNode()
    d.AutoWindowLevelOff()
    d.SetWindowLevel(600, 150)   # CT angiography: W 600 / L 150 HU


set_ct_angio_window()

# Segmentation (label map → named segments, shown in 2D only). The label map covers
# exactly the kidney/aorta region, so its bounds also define the 3D crop box.
bounds = None
if os.path.exists(p("renal_segmentation.nii.gz")):
    labels = slicer.util.loadLabelVolume(p("renal_segmentation.nii.gz"), {"show": False})
    bounds = [0.0] * 6
    labels.GetRASBounds(bounds)
    seg = slicer.mrmlScene.AddNewNodeByClass("vtkMRMLSegmentationNode", "Renal segmentation")
    slicer.modules.segmentations.logic().ImportLabelmapToSegmentationNode(labels, seg)
    slicer.mrmlScene.RemoveNode(labels)
    names = {"1": ("Aorta", (0.9, 0.2, 0.2)), "2": ("Kidney left", (0.8, 0.6, 0.3)),
             "3": ("Kidney right", (0.6, 0.8, 0.3)), "4": ("Arteries (vesselFM)", (0.2, 0.9, 0.9))}
    s = seg.GetSegmentation()
    for i in range(s.GetNumberOfSegments()):
        segment = s.GetNthSegment(i)
        name, rgb = names.get(segment.GetName(), (segment.GetName(), (1, 1, 0)))
        segment.SetName(name)
        segment.SetColor(*rgb)
    seg.CreateDefaultDisplayNodes()
    seg.GetDisplayNode().SetVisibility3D(False)
    seg.GetDisplayNode().SetOpacity2DFill(0.25)

# Candidate renal artery origins (labels in the 2D views only — they overlap in 3D)
if os.path.exists(p("renal_artery_candidates.mrk.json")):
    mk = slicer.util.loadMarkups(p("renal_artery_candidates.mrk.json"))
    mk.GetDisplayNode().SetPropertiesLabelVisibility(False)
    mk.GetDisplayNode().SetPointLabelsVisibility(False)
    mk.GetDisplayNode().SetGlyphScale(1.5)

# Volume rendering with the CT-AAA preset, cropped to the kidney/aorta region
vr = slicer.modules.volumerendering.logic()
disp = vr.CreateDefaultVolumeRenderingNodes(clean)
disp.GetVolumePropertyNode().Copy(vr.GetPresetByName("CT-AAA"))
if bounds:
    roi = slicer.mrmlScene.AddNewNodeByClass("vtkMRMLMarkupsROINode", "Renal region")
    roi.SetCenter([(bounds[0] + bounds[1]) / 2, (bounds[2] + bounds[3]) / 2, (bounds[4] + bounds[5]) / 2])
    roi.SetSize([bounds[1] - bounds[0], bounds[3] - bounds[2], bounds[5] - bounds[4]])
    roi.GetDisplayNode().SetVisibility(False)
    disp.SetAndObserveROINodeID(roi.GetID())
    disp.SetCroppingEnabled(True)
disp.SetVisibility(True)

lm = slicer.app.layoutManager()
lm.setLayout(slicer.vtkMRMLLayoutNode.SlicerLayoutFourUpView)
view = lm.threeDWidget(0).threeDView()
view.lookFromViewAxis(ctk.ctkAxesWidget.Anterior)
view.mrmlViewNode().SetBoxVisible(False)
view.mrmlViewNode().SetAxisLabelsVisible(False)
renderer = view.renderWindow().GetRenderers().GetFirstRenderer()
if bounds:
    renderer.ResetCamera(bounds)
    renderer.GetActiveCamera().Zoom(1.3)
else:
    view.resetFocalPoint()
view.forceRender()
set_ct_angio_window()   # again, after all loading/processing has finished
slicer.app.processEvents()
# and once more after the GUI has settled (interactive window computes histograms later)
import qt
qt.QTimer.singleShot(2000, set_ct_angio_window)

if os.environ.get("VESSEL_SCREENSHOT"):
    slicer.app.processEvents()
    import ScreenCapture
    ScreenCapture.ScreenCaptureLogic().captureImageFromView(view, os.environ["VESSEL_SCREENSHOT"])
    if os.environ.get("VESSEL_SLICE_SCREENSHOT"):
        red = slicer.app.layoutManager().sliceWidget("Red").sliceView()
        ScreenCapture.ScreenCaptureLogic().captureImageFromView(red, os.environ["VESSEL_SLICE_SCREENSHOT"])
    if os.environ.get("VESSEL_EXIT"):
        slicer.app.exit(0)
