#!/usr/bin/env python3
"""
Draft a radiology report from the structured findings with an LLM, in one or
more languages. Called by run-inference.sh:

    printf '%s' "$CLINICAL_SUMMARY" | python llm_report.py

The report is always drafted in English first (the prompt rules and all
published evaluations of medical LLMs are English), then translated into each
further language with a constrained prompt. Every translation is checked: if
any number differs from the English report, a warning is printed with it, so
a reader never relies on a silently altered value.

Environment (from docker/.env):
    LLM_BASE_URL, LLM_MODEL, LLM_MAX_TOKENS, LLM_TEMPERATURE, LLM_TIMEOUT,
    LLM_API_KEY            Bearer token for cloud APIs (OpenAI etc.); empty for local
    LLM_REASONING_EFFORT   ("none" turns reasoning off for thinking models)
    LLM_REPORT_LANGUAGES   comma list of codes, e.g. "en", "sk", "en,sk"
                           (default "en"; English is drafted even if not listed)
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections import Counter

LANGUAGES = {
    "en": "English", "sk": "Slovak", "cs": "Czech", "de": "German",
    "hu": "Hungarian", "pl": "Polish", "uk": "Ukrainian", "fr": "French",
    "es": "Spanish", "it": "Italian",
}

REPORT_PROMPT = """You are an experienced radiologist reviewing an AI-assisted medical imaging analysis.
Based ONLY on the structured quantitative results below, write a formal radiology report in English.

STRICT RULES — follow exactly:
  * Use the 'Modality' stated in the results. Do NOT guess or change the modality.
  * Do NOT invent normal/reference ranges. Only comment on normality when the
    results give a 'Ref' range and a Flag for that structure.
  * For any structure whose Ref is '-', report the measured volume WITHOUT any
    statement about whether it is normal, high, or low.
  * Only call a value abnormal if it is explicitly flagged ('⚠ HIGH', '⚠ LOW',
    '↑ >p90', '↓ <p10', '⚠ enlarged', '⚠ borderline').
  * Do not fabricate findings that are not present in the data below.

Report format:
  CLINICAL INDICATION: (infer from model + the stated modality only)
  TECHNIQUE: (model used, stated modality)
  FINDINGS:
    - List each structure with its measured volume; note the reference range and
      flag ONLY when one is provided
    - For detection results: describe number, location, and size of findings
    - For classification: report confidence scores and positive findings
  IMPRESSION:
    - summary of the explicitly flagged structures (if none, say so)
  RECOMMENDATION: (if applicable)

=== STRUCTURED AI ANALYSIS RESULTS ===
{summary}

Write the radiology report now:"""

# Mandatory terms per language: the model once rendered "pancreas" as the
# non-word "Slézka". Extend as reports reveal new mistakes.
GLOSSARY = {
    "sk": {
        "pancreas": "pankreas", "spleen": "slezina", "liver": "pečeň",
        "kidney": "oblička", "adrenal gland": "nadoblička", "gallbladder": "žlčník",
        "urinary bladder": "močový mechúr", "aorta": "aorta",
        "inferior vena cava": "dolná dutá žila", "portal vein": "vena portae",
        "duodenum": "duodenum", "small bowel": "tenké črevo", "colon": "hrubé črevo",
        "stomach": "žalúdok", "esophagus": "pažerák", "lung": "pľúca",
        "vertebra": "stavec", "craniocaudal": "kraniokaudálny",
        "FINDINGS": "NÁLEZ", "IMPRESSION": "ZÁVER", "RECOMMENDATION": "ODPORÚČANIE",
        "CLINICAL INDICATION": "KLINICKÁ INDIKÁCIA", "TECHNIQUE": "TECHNIKA",
    },
    "cs": {
        "pancreas": "slinivka břišní (pankreas)", "spleen": "slezina", "liver": "játra",
        "kidney": "ledvina", "adrenal gland": "nadledvina", "gallbladder": "žlučník",
        "FINDINGS": "NÁLEZ", "IMPRESSION": "ZÁVĚR", "RECOMMENDATION": "DOPORUČENÍ",
    },
}

TRANSLATE_PROMPT = """Translate the following radiology report from English into {language}.

Rules:
  * Keep EVERY number, unit, reference range, source citation (e.g. "Kim 2021",
    "J-MID p10-p90 M") and flag symbol (✓ ⚠ ↑ ↓) exactly as written. Do not round,
    convert or reformat numbers; keep the decimal point.
  * Use standard {language} radiology terminology.
  * Keep the section structure. Do not add, remove or interpret any finding.
  * Output only the translation, nothing else.
{glossary}
=== REPORT ===
{report}"""


# Lines of the summary that identify the patient or local files. The report
# does not need them, and with a cloud LLM they would leave the hospital.
IDENTIFYING_LINE = re.compile(r"^\s*(Source|Image|Patient[\w ]*|File|Path)\s*:", re.IGNORECASE)


def deidentify(summary: str) -> str:
    return "\n".join(l for l in summary.splitlines() if not IDENTIFYING_LINE.match(l))


def _post(body: dict) -> dict:
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if os.getenv("LLM_API_KEY"):
        headers["Authorization"] = "Bearer " + os.environ["LLM_API_KEY"]
    req = urllib.request.Request(
        os.getenv("LLM_BASE_URL", "http://localhost:1234").rstrip("/") + "/v1/chat/completions",
        data=json.dumps(body).encode("utf-8"), headers=headers, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=int(os.getenv("LLM_TIMEOUT", "300"))) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:400]}") from None


def chat(prompt: str) -> str:
    body = {
        "model": os.getenv("LLM_MODEL", ""),
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": int(os.getenv("LLM_MAX_TOKENS", "2048")),
        "temperature": float(os.getenv("LLM_TEMPERATURE", "0.2")),
        "stream": False,
    }
    if os.getenv("LLM_REASONING_EFFORT"):
        body["reasoning_effort"] = os.environ["LLM_REASONING_EFFORT"]
    # Cloud APIs differ: newer OpenAI models want max_completion_tokens and reject a
    # custom temperature or some reasoning_effort values. Adapt once on a 400.
    for _ in range(4):
        try:
            result = _post(body)
            break
        except RuntimeError as e:
            msg = str(e)
            if "max_tokens" in msg and "max_tokens" in body:
                body["max_completion_tokens"] = body.pop("max_tokens")
            elif "temperature" in msg and "temperature" in body:
                body.pop("temperature")
            elif "reasoning_effort" in msg and "reasoning_effort" in body:
                body.pop("reasoning_effort")
            else:
                raise
    choice = result["choices"][0]
    text = (choice["message"].get("content") or "").strip()
    if not text:
        used = (result.get("usage", {}).get("completion_tokens_details") or {}).get("reasoning_tokens")
        raise RuntimeError(
            f"empty response (finish_reason={choice.get('finish_reason')}, reasoning_tokens={used}) — "
            "a thinking model probably used the whole LLM_MAX_TOKENS on reasoning; set "
            "LLM_REASONING_EFFORT=none or raise LLM_MAX_TOKENS in docker/.env")
    return text


def numbers(text: str) -> Counter:
    """Numbers in a text, decimal comma normalised to a point (sk/cs/de style)."""
    return Counter(n.replace(",", ".") for n in re.findall(r"\d+(?:[.,]\d+)?", text))


def number_mismatch(source: str, translation: str) -> list[str]:
    a, b = numbers(source), numbers(translation)
    missing = sorted((a - b).elements())
    added = sorted((b - a).elements())
    out = []
    if missing:
        out.append("missing " + ", ".join(missing[:15]))
    if added:
        out.append("changed/added " + ", ".join(added[:15]))
    return out


def main() -> int:
    summary = sys.stdin.read()
    codes = [c.strip().lower() for c in os.getenv("LLM_REPORT_LANGUAGES", "en").split(",") if c.strip()] or ["en"]
    try:
        english = chat(REPORT_PROMPT.format(summary=deidentify(summary)))
    except Exception as e:
        print(f"[LLM] Not available: {e}", file=sys.stderr)
        print("[Report generation failed — see the warning above]")
        return 0

    sections = []
    for code in codes:
        if code == "en":
            sections.append(("EN", english))
            continue
        language = LANGUAGES.get(code, code)
        try:
            terms = GLOSSARY.get(code, {})
            glossary = ("  * Use EXACTLY these terms (English → " + language + "):\n" +
                        "".join(f"      {en} → {tr}\n" for en, tr in terms.items())) if terms else ""
            text = chat(TRANSLATE_PROMPT.format(language=language, report=english, glossary=glossary))
        except Exception as e:
            sections.append((code.upper(), f"[Translation to {language} failed: {e}]"))
            continue
        problems = number_mismatch(english, text)
        if problems:
            text = (f"⚠ TRANSLATION CHECK: numbers differ from the English report "
                    f"({'; '.join(problems)}) — rely on the English version.\n\n" + text)
        sections.append((code.upper(), text))

    if "en" not in codes:
        # English is the checked source of every translation — keep it for audit.
        sections.append(("EN (source of the translation)", english))

    for i, (label, text) in enumerate(sections):
        if i:
            print()
        print(f"--- REPORT ({label}) ---")
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
