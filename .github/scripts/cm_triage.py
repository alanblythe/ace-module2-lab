#!/usr/bin/env python3
"""Triage a CodeMender JSON report for the CI/CD guardrail (Module 2 lab).

Reads the output of `cm report -f json`, then:
  * counts HIGH / CRITICAL findings (these block deployment),
  * picks the single highest-priority finding to auto-remediate,
  * writes a human-readable table to the GitHub Actions job summary,
  * exposes step outputs the workflow uses for the fix / PR / gate steps.

This script NEVER exits non-zero — the workflow's dedicated "Security Gate"
step owns the pass/fail decision (so the fix + PR steps run first). Robust to
`cm` printing a banner before the JSON: it carves out the first JSON value.

Usage: cm_triage.py <path-to-report.json>
"""
from __future__ import annotations

import json
import os
import sys

# Severity ranking — higher blocks deployment. CRITICAL first when choosing
# which finding to auto-fix.
RANK = {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1, "INFO": 0, "": 0}
BLOCKING = {"CRITICAL", "HIGH"}


def _get(d: dict, *keys, default=""):
    """First present key wins (handles PascalCase + snake_case report shapes)."""
    for k in keys:
        if k in d and d[k] not in (None, ""):
            return d[k]
    return default


def extract_findings(raw: str) -> list[dict]:
    """Parse the report text into a list of finding dicts, tolerating a banner."""
    s = (raw or "").strip()
    if not s:
        return []
    # Try a clean parse first, then carve the first [..] or {..} value.
    candidates = [s]
    for opener, closer in (("[", "]"), ("{", "}")):
        i, j = s.find(opener), s.rfind(closer)
        if i != -1 and j > i:
            candidates.append(s[i : j + 1])
    for c in candidates:
        try:
            data = json.loads(c)
        except json.JSONDecodeError:
            continue
        if isinstance(data, list):
            return [x for x in data if isinstance(x, dict)]
        if isinstance(data, dict):
            # Some report shapes wrap findings under a key.
            for key in ("findings", "Findings", "results", "data"):
                if isinstance(data.get(key), list):
                    return [x for x in data[key] if isinstance(x, dict)]
            return [data]  # single finding object
    return []


def severity_of(f: dict) -> str:
    return str(_get(f, "Severity", "severity", default="")).upper()


def set_output(name: str, value: str) -> None:
    out = os.environ.get("GITHUB_OUTPUT")
    # Multiline-safe heredoc form.
    line = f"{name}<<__CM_EOF__\n{value}\n__CM_EOF__\n"
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line)
    else:  # local run / debugging
        sys.stderr.write(f"[output] {name}={value!r}\n")


def write_summary(md: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(md + "\n")
    else:
        sys.stderr.write(md + "\n")


def main() -> int:
    report_path = sys.argv[1] if len(sys.argv) > 1 else ""
    raw = ""
    if report_path and os.path.exists(report_path):
        with open(report_path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()

    findings = extract_findings(raw)

    counts = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0, "OTHER": 0}
    for f in findings:
        sev = severity_of(f)
        counts[sev if sev in counts else "OTHER"] += 1

    high_critical = counts["CRITICAL"] + counts["HIGH"]

    # Choose the finding to auto-remediate: highest severity, then highest
    # confidence, among the blocking findings.
    def conf(f: dict) -> int:
        try:
            return int(_get(f, "Confidence", "confidence", default=0) or 0)
        except (TypeError, ValueError):
            return 0

    try:
        limit = max(1, int(os.environ.get("CM_FIX_LIMIT", "3") or "3"))
    except ValueError:
        limit = 3

    blocking = [f for f in findings if severity_of(f) in BLOCKING]
    blocking.sort(key=lambda f: (RANK.get(severity_of(f), 0), conf(f)), reverse=True)
    selected = blocking[:limit]   # the top-N HIGH/CRITICAL we auto-remediate

    def fid(f):
        return str(_get(f, "FindingID", "finding_id", "id", default=""))

    def ftitle(f):
        return str(_get(f, "Title", "title", default="(untitled)"))

    def ffile(f):
        return str(_get(f, "FilePath", "file_path", "file", default="-"))

    top = selected[0] if selected else {}
    fix_ids = " ".join(i for i in (fid(f) for f in selected) if i)
    fix_summary = "\n".join(
        f"- **{severity_of(f)}** — {ftitle(f)}  \n  `{ffile(f)}` (`{fid(f)}`)" for f in selected
    ) or "_none_"

    # --- step outputs ---
    set_output("total", str(len(findings)))
    set_output("high_critical", str(high_critical))
    set_output("fix_ids", fix_ids)                       # space-separated top-N ids to fix
    set_output("fix_count", str(len(selected)))
    set_output("fix_summary", fix_summary)               # markdown list for the PR body
    set_output("top_finding_id", fid(top))               # first one (PR title fallback)
    set_output("top_finding_title", ftitle(top))
    set_output("top_finding_severity", severity_of(top) or "-")
    set_output("top_finding_file", ffile(top))

    # --- job summary ---
    gate = "❌ BLOCK (HIGH/CRITICAL present)" if high_critical else "✅ PASS"
    lines = [
        "## 🛡️ CodeMender Triage",
        "",
        f"**Total findings:** {len(findings)}  |  **Gate:** {gate}",
        "",
        "| Severity | Count |",
        "|---|---|",
        f"| 🔴 CRITICAL | {counts['CRITICAL']} |",
        f"| 🟠 HIGH | {counts['HIGH']} |",
        f"| 🟡 MEDIUM | {counts['MEDIUM']} |",
        f"| ⚪ LOW | {counts['LOW']} |",
    ]
    if counts["OTHER"]:
        lines.append(f"| ❔ OTHER | {counts['OTHER']} |")
    if selected:
        lines += ["", f"### 🎯 Selected for autonomous remediation (top {len(selected)})", ""]
        for f in selected:
            lines.append(f"- **{severity_of(f)}** — {ftitle(f)} — `{ffile(f)}` (`{fid(f)}`)")
    write_summary("\n".join(lines))

    # Console echo (visible in the step log).
    print(f"total={len(findings)} high_critical={high_critical} "
          f"fix_count={len(selected)} fix_ids={fix_ids or '(none)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
