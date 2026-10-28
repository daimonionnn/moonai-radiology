# Project rationale: does it make sense, and what are the alternatives?

**Short answer: yes, as a research platform with a radiologist in the loop. Not as a
shortcut to a certified clinical product.**

The project (planned new name: **MOONAI** — *Medical (not only for) Oncology Open
Network For AI*) assembles best-in-class open-source parts — MONAI Label, Orthanc,
OHIF, 3D Slicer, TotalSegmentator and a local LLM for report drafting — into one
self-hosted workflow. For an oncology institute that gives three things commercial
products usually don't:

- **One platform for many modalities.** CT, MRI, X-ray, mammography and pathology in
  one place, instead of one paid licence per modality or task.
- **Fast extension.** A new capability (e.g. segmenting another organ or lesion
  type) is a new model plugged into an existing pipeline — days of work, not a
  procurement cycle.
- **Data stays in the hospital.** Everything runs on-premise; no images leave the
  network, which keeps GDPR scope small.

The long-term goal is to label existing studies (CT, MRI, mammography, …), fine-tune
models on them, and experimentally evaluate the system at an oncology institute as a
**"second pair of eyes"** — it assists the radiologist and never replaces the second
read.

## What it is good for — and what it is not

| Use | Verdict |
|---|---|
| Research, education, prototyping AI-assisted workflows | Good fit — this is what it is built for |
| Faster labeling (AI pre-labels, physician corrects) | Good fit — builds a local labeled dataset, valuable for research and grants |
| Volumetry and lesion follow-up measurements in research studies | Good fit once validated per task on local data |
| Routine clinical use influencing diagnosis | **Not without** CE/MDR certification or the MDR in-house exemption — see below |

Be realistic about the effort: real clinical deployment means certification, clinical
validation on local data and GDPR/data governance. That is a separate, large project —
not a coding question. The project so far took roughly three weekends; it is a
working proof of concept showing how to continue.

## Lessons from building it

The biggest risk turned out to be **how results are interpreted, not the models
themselves** (details in [REVIEW_AND_TODO](REVIEW_AND_TODO.md) §1):

- The LLM invented "normal ranges" when none were supplied. Fixed: reference ranges
  and flags are computed in Python; the LLM only words the numbers it is given.
- Organ volumes were under-counted because of a broken DICOM→NIfTI path. Fixed: the
  liver volume now matches TotalSegmentator within ~1 %.
- Every number must be checked against an independent tool and a physician.

## Alternatives

No single existing project replaces the whole integration — combining the components
into one workflow *is* the added value. But for individual tasks there are strong
options, and some should be used inside this platform rather than competing with it.

### Open source

| Tool | What it does | Relation to this project |
|---|---|---|
| **TotalSegmentator v2** | 117 CT / 50 MR structures, robust, runs on CPU too | Already integrated as reference; should become the primary organ segmenter (replaces `wholeBody_ct_segmentation`, `swin_unetr_btcv`) |
| **nnU-Net / nnDetection** | Gold-standard training frameworks | For training own tumor/lesion models later |
| **nnInteractive, MedSAM2** | Interactive (click/box) 3D segmentation | Fast lesion labeling; nnInteractive has 3D Slicer and OHIF clients |
| **ULS+ / ULS23, LesionLocator** | Click-to-segment any CT lesion; lesion tracking across follow-ups | Main oncology gap: RECIST-style measurement and follow-up |
| **Kaapana (DKFZ Heidelberg)** | Open-source research AI platform for hospitals | Closest open-source alternative — evaluate before investing further |
| **3D Slicer extensions** | TotalSegmentator, MONAILabel, SlicerRadiomics | Desktop path, already supported |
| Data & models | grand-challenge.org, Medical Segmentation Decathlon, TCIA | Sources of pretrained models and public test data |

### Commercial (CE-marked)

| Product / platform | Area |
|---|---|
| Transpara (ScreenPoint), Lunit INSIGHT MMG | Mammography |
| Lunit INSIGHT CXR, Annalise Enterprise, Qure.ai, Carebot | Chest X-ray |
| Gleamer BoneView, Rayscape | Fractures / X-ray (used in Penta Hospitals, Slovakia) |
| Aidoc, Siemens AI-Rad Companion | CT findings, volumetry |
| deepcOS, CARPL | AI marketplaces — many certified apps via one platform, paid per module |

These are certified but closed, paid, and mostly narrow (one modality, one task).
Where a certified product exists (mammography, chest X-ray, fractures), buying it for
clinical use and keeping this platform for research and for gaps is the sensible
split.

The full model survey (with sources, licences and a prioritized list of what to add,
focused on oncology) is in the research report `reports/Better models for MOONAI.md`
(untracked; Slovak original in [SK/LEPSIE_MODELY_PRE_MOONAI.md](SK/LEPSIE_MODELY_PRE_MOONAI.md));
the resulting tasks are in
[REVIEW_AND_TODO](REVIEW_AND_TODO.md) §5.

## Regulatory note (EU / Slovakia)

Being "only an aid" does **not** exempt software from regulation — the intended
purpose decides. Software that supports diagnosis of a specific patient is a medical
device under **MDR (EU) 2017/745** (Rule 11, typically class IIa+). The **AI Act
(EU) 2024/1689** classifies such AI as high-risk (obligations from August 2027 at the
earliest; the Digital Omnibus may move this to 2028). Health data falls under
**GDPR** Art. 9 and Slovak Act No. 18/2018.

Legal paths, from easiest:

1. Retrospective research on anonymized studies, with ethics-committee approval and a
   DPIA, with no influence on patient care.
2. Prospective "shadow mode" study — AI runs alongside routine reading under a study
   protocol (an MDR clinical investigation if it influences physicians; notify ŠÚKL).
3. Routine use — MDR Art. 5(5) in-house exemption or CE certification.

None of the open models listed above is CE-certified; their output must stay labeled
as research-only. This is an orientation, not legal advice — confirm with the
hospital's legal department, data protection officer and ethics committee.

See also: [RADIOLOGIST_SUMMARY](RADIOLOGIST_SUMMARY.md) — the project summary written
for a cooperating radiologist.
