# MOONAI – Medical (not only for) Oncology Open Network For AI

Project summary for a cooperating radiologist · 19 October 2026, extended 20 October 2026
English translation of [SK/SUMAR_PRE_RADIOLOGA.md](SK/SUMAR_PRE_RADIOLOGA.md) (the Slovak original is the version shared with the hospital).
Background and alternatives in more depth: [PROJECT_RATIONALE](PROJECT_RATIONALE.md).

## Short summary

MOONAI is a working prototype of an open platform that assists the radiologist: it segments organs and lesions, computes volumes, looks for suspicious findings and drafts a structured report. It is built from proven open-source components (MONAI, Orthanc, OHIF, 3D Slicer, TotalSegmentator) and runs entirely inside the hospital, so patient data never leaves it.

**Why do it.** Commercial AI assistants are expensive and mostly cover one area (mammography only, chest X-ray only, head CT only). MOONAI is one platform for CT, MRI, X-ray, mammography and pathology. New functions (e.g. segmenting another organ) can be added in days, not years.

**Where we are.** It is a concept I worked on for about three weekends. The full chain works: DICOM, AI model, volumes and draft report. On a test CT the liver volume matches the independent tool TotalSegmentator within ~1 %. The results are not yet clinically validated.

**Is it legal?** As research, yes; as a routine clinical tool, not yet. Under the EU MDR, software that assists diagnosis is a medical device even if it only supports the physician and does not replace the second read. There are three legal paths:

1. A retrospective study on anonymized images with ethics-committee approval, with no influence on patient treatment.
2. A clinical study in which the AI runs "in the shadow" alongside routine practice.
3. Later, the MDR in-house exemption for tools developed and used within one hospital, or CE certification.

**Proposed next step.** A small retrospective pilot in one area (e.g. CT organ volumetry or mammography): you label a sample of studies, I train and evaluate the model, and together we measure whether it actually saves the radiologist time or catches findings. It makes sense even as research rather than a product. The long-term core of the project is fine-tuning on the hospital's data in an area commercial products do not cover, such as testicular tumors.

## What MOONAI is and how it works

MOONAI combines a viewer, an image store, AI models and report drafting into one workflow. The physician always has the final word.

```
Images (PACS: CT, MR, X-ray, mammography)
   → Orthanc (DICOM store, anonymization on import)
   → MONAI AI models (segmentation, detection; 11 pretrained models)
   → Computation in code (volumes, reference ranges, out-of-range flags)
   → Language model (draft report only from the computed numbers)
   → Radiologist (OHIF viewer / 3D Slicer; reviews and signs)
        └─ physician's corrections → labeling and fine-tuning → new model version → AI models
```

Images flow from PACS through anonymization to the AI models. Numbers are computed and checked in code; the language model only phrases a draft text from them, and the radiologist reviews everything. The radiologist's corrections flow back as training data, so the models gradually adapt to the images and scanners of the particular hospital.

## Current state of the concept

The full chain works end to end on one machine with a GPU, or more slowly on CPU only. Nothing is clinically validated yet. The work took about three weekends.

| Area | Status | Note |
| --- | --- | --- |
| Infrastructure (Orthanc, OHIF, MONAI Label, 3D Slicer) | Working | Started with one script, everything local |
| Pretrained models | 11 models deployed | CT organs (whole body, pancreas, VISTA-3D), lung nodules, brain MRI (133 structures, BraTS tumors), prostate MRI, breast density, pathology |
| CT organ volumetry | Working, verified on 1 study | Liver 1579 cm³ vs 1595 cm³ from TotalSegmentator; kidneys within 3 % |
| Lung nodule detection | Technically working | Not yet verified on a study with a known nodule |
| Draft report via language model (LLM) | Working | Reference ranges and flags are computed in code; the model may no longer invent them |
| Labeling and fine-tuning own models | Prepared, not tried on real data | Needs physician-labeled images |
| Mammography | Density classification only | Lesion detection missing; needs data or another model |
| Security, audit, access control | Missing | Prerequisite for any deployment in a hospital |

Debugging showed that the biggest risk is not the model itself but how results are interpreted. The first version under-counted volumes (faulty DICOM conversion), and the language model invented "normal ranges". Both are fixed, and the lesson is clear: every number must be verified against an independent source and a physician.

## Does it make sense?

Yes, as a research project with a physician in the loop. Not as a quick path to a certified product. The biggest value is that the oncology institute gains its own cheap, extensible platform and its own labeled data.

**Benefits**

- **Volumetry and follow-up over time.** Automatic organ and lesion volumes save manual measurement, e.g. when assessing treatment response.
- **One platform for several modalities.** CT, MRI, X-ray, mammography and pathology in one environment instead of several paid licences.
- **Fast labeling.** The AI proposes a contour and the physician only corrects it — several times faster than drawing from scratch.
- **Own data as an asset.** A labeled image set from the local population and scanners has value for research, publications and grant projects.
- **Data stays in the hospital.** Everything runs locally, no cloud. This greatly simplifies GDPR.
- **Mammography.** Results of the large Swedish MASAI trial suggest AI in screening can reduce radiologists' workload by roughly 40 % without lowering the detection rate. That, however, concerns a certified commercial system.

**Limits and risks**

- **Clinical validation is the main work.** A model that works on public data may perform worse on images from a different scanner. Every task needs measurement on local data.
- **Automation bias.** Even "just an aid" influences the physician. A false-negative AI result can reduce attention.
- **The language model is not a diagnostician.** It may only phrase numbers computed by code. If it inferred anything on its own, that would be dangerous.
- **Capacity.** Today the project is one person and a few weekends. Running it in a hospital needs IT support, backups, updates and a responsible person.
- **Law.** Without certification or an exemption, the outputs must not be used for decisions about patients (see Legal framework).

## Core of the project: training on the hospital's own data

The real value of MOONAI does not come from the ready-made models but from fine-tuning them on images taken directly from the hospital. It makes the most sense in an area that commercial products do not cover and that is under-researched, for example testicular tumors.

**What it would change, using testicular tumors as an example**

- **A gap in the market.** I know of no certified AI product or high-quality open model for this area (not yet specifically verified). Open models for lymph nodes are missing entirely, according to my research.
- **Concrete tasks.** Segmentation and volumetry of retroperitoneal lymph nodes on CT and their follow-up over time (response to chemotherapy, residual masses). Later, possibly assessment of lesions on ultrasound.
- **A unique dataset.** A labeled cohort from the institute itself is publishable and valuable for grants.
- **An easier legal path.** When no equivalent certified product exists on the market, the MDR in-house exemption is easier to justify.
- **Limit.** It is a rare disease, so the archive of several years needs to be included.

**Effort estimate for one task (e.g. lymph nodes on CT)**

| Activity | Who | Estimate |
| --- | --- | --- |
| Selecting studies from PACS and anonymization | resident or technician, programmer | 2–5 days |
| Labeling 150–300 studies with AI pre-labels | 2–3 radiologists | 10–20 min per study, about 25–100 hours in total |
| Checking the test sample (about 50 studies) | second radiologist | 10–20 hours |
| Deployment in the hospital, PACS connection | programmer, hospital IT | 1–2 weeks |
| Training, evaluation, adjustments | programmer | 1–2 months alongside a job |

In practice this means 2–4 hours a week from 2–3 physicians over 2–4 months. The estimates are approximate and will be refined after a pilot labeling of 10–20 studies.

**Operation and costs**

- **The software is free.** All components are open source, with no per-study licences. Models can be added, replaced or reconfigured at any time. The costs are hardware (one GPU server, on the order of a few thousand euros), electricity and above all people's time. Some models are licensed for non-commercial use only, which is enough for research.
- **Throughput.** On the current hardware (one RTX PRO 6000 GPU with 96 GB) the imaging models and the language model run at the same time on one card. A CT segmentation takes from tens of seconds to a few minutes. A smaller 32 GB card (e.g. RTX 5090) would most likely also be enough for image processing, with the language model running on another machine. In overnight batch mode that is hundreds of studies; thousands per week.
- **Several users at once.** Several physicians can work simultaneously through the web viewer. GPU jobs are queued. It has not been load-tested yet.

## Existing alternatives

Alternatives exist, but none covers everything at once, cheaply and under the hospital's own control. Commercial products are certified but paid and mostly narrow. Open-source tools are high-quality but each solves only part of the task. MOONAI combines them into one workflow.

| Solution | Type | Focus | Relation to MOONAI |
| --- | --- | --- | --- |
| Transpara (ScreenPoint), Lunit INSIGHT MMG | Commercial, CE | Mammography | Certified alternative for mammography, licensed per study or per year |
| Lunit INSIGHT CXR, Annalise.ai, Gleamer BoneView | Commercial, CE | Chest X-ray, fractures | One modality, one task |
| Aidoc, Siemens AI-Rad Companion | Commercial, CE | CT findings, volumetry | Broader, but expensive and vendor-bound |
| deepc, Blackford, CARPL | Commercial AI marketplaces | Access to many certified AI apps at once | Closest commercial analogue of the platform, paid per module |
| Kaapana (DKFZ Heidelberg) | Open-source platform | Research AI platform for hospitals | Closest open-source alternative; worth comparing before further development |
| TotalSegmentator | Open source | Segmentation of 100+ structures on CT and MR | Already part of MOONAI as a reference |
| nnU-Net, MedSAM | Open source | Training own models, interactive segmentation | Planned for training and fast labeling |
| 3D Slicer, MONAI Label, OHIF, Orthanc | Open source | Viewer, annotation, DICOM store | Building blocks of MOONAI |

## Comparison: MOONAI, commercial systems and ChatGPT / Claude

Each of the three approaches is strong at something different. Commercial systems have certification and validation. MOONAI has control over the data, low cost and can be extended. General chatbots excel at working with text but are not built to read images.

| Criterion | MOONAI | Commercial (Transpara, Aidoc, …) | ChatGPT / Claude with images |
| --- | --- | --- | --- |
| Working with 3D CT and MRI | Full 3D, Hounsfield units, exact mm | Full 3D | A JPG is one slice without HU or 3D context. DICOM can only be opened via code, without validated models |
| Accuracy | Segmentation and volumetry at state-of-the-art level; detection not yet validated | Validated on large multi-center data | Often wrong and invent findings when reading images |
| Certification | No, research only | CE / MDR | No |
| Data protection | Everything stays in the hospital | On-premise or EU cloud under contract | Data goes to a cloud outside the hospital. DICOM headers contain the name and national ID number |
| Cost | Software free; you pay for hardware and time | Tens of thousands of euros a year or more (e.g. deepc GBP 5–150k per licence per year) | Cheap subscription with limits; API paid per token |
| Breadth and extensibility | Any task, own models | Narrow, limited to the vendor's offer | Broad but shallow |
| Text, reports, literature | Local language model, weaker than top models | Limited | Strongest |

**Can MOONAI with a high-quality language model reach the level of commercial systems?** Partly yes, but not because of the language model. Image-reading accuracy is determined by specialized vision models. A better language model improves report wording, handling of findings and agent tasks — not detection sensitivity.

- **Segmentation and volumetry.** Open models are on par with commercial ones. TotalSegmentator is even a component of several FDA-cleared commercial products.
- **Detection (mammography, chest X-ray).** Commercial systems are trained on large volumes of images and validated. Open models lag behind or are not validated on other scanners. For example, the Mirai mammography model dropped almost to chance level on another vendor's images.
- **Narrow areas (testicular tumors, lymph nodes).** No commercial product exists, so a model fine-tuned on local data may be the best available.
- **Certification.** No language model replaces it.

**Local agent versus cloud services**

- **Local language model in MOONAI.** No per-token fees or limits; it can run all night over thousands of studies: batch processing of the archive, comparison with prior studies, report drafts. Data never leaves the hospital. The drawback is that local models are weaker than top cloud models in reasoning and in Slovak.
- **ChatGPT, Claude or Perplexity subscription.** The highest quality of text and literature research, but with usage limits. Not suitable for patient data.
- **Own agent with a paid API.** Top quality without subscription limits, but costs add up quickly over hours of running.
- **Recommendation: hybrid.** Everything involving patient data runs locally (MOONAI and a local language model). Tasks without patient data, such as researching studies or guidelines, can go through a cloud API.

## Legal framework

Being "just an aid" that does not replace the second read does not by itself exempt the AI from regulation. The intended purpose decides: if the software's output influences the diagnosis of a specific patient, it is a medical device. Using MOONAI for research is legal. Routine diagnostic use requires certification or the in-house exemption.

**Three regulations that apply**

- **MDR (Regulation (EU) 2017/745).** Software supporting diagnosis is a medical device, under Rule 11 usually class IIa or higher. In Slovakia the competent authority is ŠÚKL.
- **AI Act (Regulation (EU) 2024/1689).** AI that is a medical device assessed by a notified body is a high-risk system. Its obligations apply from August 2027 at the earliest (the date may shift). Pure research and development is exempt from the AI Act.
- **GDPR and Slovak Act No. 18/2018.** Health data is a special category. A legal basis, anonymization or pseudonymization, a data protection impact assessment (DPIA) and the approval of the hospital's data protection officer are required.

**Possible paths depending on how the AI is used**

| Scenario | Impact on the patient | What is needed | Difficulty |
| --- | --- | --- | --- |
| Retrospective research on older, anonymized images | None | Ethics committee, agreement with the hospital, anonymization, DPIA | Low — suitable to start |
| Labeling and training models on own data | None | Same as above | Low |
| Prospective "shadow" testing (AI runs, physician reports as usual) | None or minimal | Study protocol, ethics committee; if it influences the physician, also an MDR clinical investigation and notification of ŠÚKL | Medium |
| Routine use as an aid when reporting | Yes | MDR in-house exemption (Art. 5(5)) or CE certification | High |

**The in-house exemption (MDR Art. 5(5))** allows a hospital to use a tool it developed itself without a CE mark. Conditions: the tool is not transferred to another entity, the hospital has a quality management system and documentation, and it justifies why its needs cannot be met by a certified product on the market. The last point is harder for mammography, where certified products exist, and easier for specific oncology tasks.

This is an orientation overview, not a legal opinion. Before the cooperation starts it must be checked with the hospital's legal department, data protection officer and ethics committee.

## Proposed cooperation

We start with a small retrospective pilot in one area with no impact on patients. Each next step depends on the measured results of the previous one.

1. **Agreement and approval.** A cooperation agreement or research project, ethics-committee approval, DPIA and a responsible physician on the hospital side.
2. **Deployment in the hospital.** MOONAI on a dedicated GPU server in the hospital network, without internet access, with anonymization on image import.
3. **Choosing one task.** Proposal: CT organ and lesion volumetry (closest to ready) or lesion detection in mammography (largest benefit, but needs data and a comparison with commercial products).
4. **Labeling.** The radiologist labels or corrects AI proposals on a sample of studies. The number depends on the task, typically tens to hundreds.
5. **Training and evaluation.** Fine-tuning the model and measuring on a separate test set: agreement with the physician (Dice, sensitivity, specificity) and time saved per study.
6. **Decision.** If results are good, "shadow" testing and possibly a publication follow. If not, the task changes or the project ends at low cost.

Realistically the pilot (steps 2–5) can take several months when done alongside a job. Labeling and approvals take the most time, not programming.

## Open questions for the radiologist

- [ ] Which task would save you the most time or help most in daily practice?
- [ ] Who in the hospital decides on research cooperation, and who is the data protection officer?
- [ ] Does the oncology institute have experience with the ethics committee for retrospective imaging studies?
- [ ] Can the hospital run its own GPU server, or does the hardware need to be secured another way (grant, sponsor)?
- [ ] How much time could you or your colleagues devote to labeling, e.g. an hour a week?
- [ ] Does the institute already use a commercial AI tool, or is it considering one?
