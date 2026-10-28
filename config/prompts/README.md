# LLM prompts

Prompts used by `scripts/inference/llm_report.py` to draft radiology reports.
Edit them as plain text — no programming needed. The set in use is chosen by
`LLM_PROMPT_DIR` in `docker/.env` (default `config/prompts`); copy this folder
(e.g. to `config/prompts-oncology`) to keep several variants. Every
`report.txt` records which set and which version (hash) produced it.

| File | Purpose | Placeholders |
|---|---|---|
| `report.md` | Draft the report in English from the computed findings | `{summary}` |
| `translate.md` | Translate the English report into another language | `{language}`, `{report}`, `{glossary}` |
| `glossary.json` | Mandatory terms per language code (`"sk"`, `"cs"`, …) | — |

Placeholders are replaced literally, so other braces in the text are safe.
A missing file falls back to the built-in default in `llm_report.py`.

Keep the core safety rules in `report.md`: use only the given numbers, never
invent reference ranges, call a value abnormal only when it is flagged. The
translation's numbers are checked against the English report in code, whatever
the prompt says.
