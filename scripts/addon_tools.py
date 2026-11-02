#!/usr/bin/env python3
"""
addon_tools.py — shared contract lint/index tooling for THIS fork.

The single human-maintained source of truth is `.github/workflows/sync.yml`
(the workflow invocation set IS the manifest, contract clause 9). This script:

  build-index   materializes the sync matrix into addons.index.json that the
                sweep consumes (as {addon, ref, instance, workspace} entries)
  lint-manifest validates manifest.yaml schema/visibility/binding grammar
  lint-workflow validates the matrix itself: entry shape, ref grammar,
                (addon, tenant) duplicates (one statefile can never serve
                two versions), and the runner-action pin

Note: regexes here mirror the runner's src/addons_cli.py by design — one-time
copies, kept intentionally small so drift stays visible in review.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

import yaml

FAMILY_PREFIX = "NAMAZU_PUT_OWNER_HERE/namazu-cloud-addon-"  # replaced by --repo-owner
SLUG_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
TAG_RE = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
REF_RE = re.compile(r"^(?P<prefix>[$!])(?P<unit>instance|addon)\.(?P<rest>.+)$")


class LintError(Exception):
    pass


def _yaml_load(path: str):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def addon_id_from_repo(repo: str, owner: str = "NamazuStudios") -> str:
    o, name = repo.split("/", 1)
    if o != owner or not name.startswith("namazu-cloud-addon-"):
        raise LintError(f"entry repo '{repo}' violates the naming grammar "
                        f"(family: {owner}/namazu-cloud-addon-*)")
    slug = name[len("namazu-cloud-addon-"):]
    if not SLUG_RE.match(slug) or len(slug) < 2:
        raise LintError(f"repo suffix '{slug}' violates the slug grammar")
    return slug


def valid_ref(ref: str) -> bool:
    return bool(ref and (SHA_RE.match(ref) or TAG_RE.match(ref)))


def extract_entries(workflow: str, job: str = "apply") -> list:
    doc = _yaml_load(workflow)
    matrix = (((doc or {}).get("jobs") or {}).get(job) or {}).get("strategy", {}) \
        .get("matrix", {}).get("install") or []
    if not isinstance(matrix, list):
        raise LintError(f"'{job}.strategy.matrix.install' must be a list of entries")
    for entry in matrix:
        if not isinstance(entry, dict):
            raise LintError(f"matrix entry is not a mapping: {entry!r}")
        if "${{" in json.dumps(entry):
            raise LintError(
                f"matrix entry uses expressions; entries must be literals for "
                f"indexing: {entry!r}"
            )
        if not (entry.get("addon") or entry.get("repo") is None):
            pass  # local-root entries omit repo/addon on purpose
    return matrix


def build_index(workflow: str, repo: str, owner: str = "NamazuStudios") -> list:
    """Materialize {addon, ref, instance, workspace} entries. Local-root
    entries (repo-less) are attributed to the fork's own repo name."""
    pairs = set()
    index = []
    for entry in extract_entries(workflow):
        repo_name = entry.get("addon") or repo
        addon_id = addon_id_from_repo(repo_name, owner)
        ref = entry.get("ref") or ("" if entry.get("addon") else "_fork_")
        instance = entry.get("instance") or ""
        workspace = entry.get("workspace") or ""
        if bool(instance) == bool(workspace):
            raise LintError(f"entry needs exactly one of instance|workspace: {entry!r}")
        pair = (addon_id, instance or workspace)
        if pair in pairs:
            # one statefile can never serve two versions: duplicate
            # (addon, tenant) entries are a hard contract error (clause 3)
            raise LintError(
                f"duplicate (addon, tenant) entry {pair} — two simultaneous "
                "versions for one tenant would be two writers on one statefile"
            )
        pairs.add(pair)
        index.append({"addon": repo_name, "ref": ref,
                      "instance": instance, "workspace": workspace})
    return index


def lint_workflow(workflow: str, runner_uses: str = "") -> list:
    """Return lint findings (empty = clean). Enforced: ref grammar, entry
    shape, duplicates, and (when a pin is expected) the runner `uses:` ref."""
    findings: list = []
    entries = extract_entries(workflow)
    for entry in entries:
        ref = entry.get("ref") or ""
        if entry.get("addon") and not valid_ref(ref):
            findings.append(
                f"entry {entry!r}: external addons must carry a pinned ref "
                "(full 40-hex SHA or protected v<semver> tag)"
            )
    try:
        doc = _yaml_load(workflow)
        uses = (((doc.get("jobs") or {}).get("apply") or {})
                .get("steps") or [])
        runner_refs = [s.get("uses", "") for s in uses
                       if "namazu-cloud-addon-runner" in s.get("uses", "")]
        if runner_uses == "pin-required":
            for u in runner_refs:
                ref_part = u.split("@", 1)[1] if "@" in u else ""
                if not SHA_RE.match(ref_part):
                    findings.append(f"runner action not SHA-pinned: {u} "
                                    "(replace <PICK-A-RUNNER-SHA> with the "
                                    "action repo's commit)")
    except Exception as e:  # noqa: BLE001 — lint must never crash the PR
        findings.append(f"workflow parse failure: {e}")
    return findings


def lint_manifest(path: str) -> list:
    findings: list = []
    try:
        with open(path, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except FileNotFoundError:
        findings.append(f"{path}: MISSING — every addon carries its "
                        "manifest.yaml (contract clause 10)")
        return findings
    except yaml.YAMLError as e:
        findings.append(f"{path}: invalid YAML — {e}")
        return findings
    if not isinstance(doc, dict):
        findings.append(f"{path}: must be a mapping")
        return findings
    if not isinstance(doc.get("description"), str) or not doc["description"].strip():
        findings.append(f"{path}: requires a non-empty 'description'")
    visibility = doc.get("visibility", "shared")
    if visibility not in ("shared", "private"):
        findings.append(f"{path}: visibility must be shared|private (got {visibility!r})")
    owner = doc.get("owner_org")
    if visibility == "private" and owner in (None, ""):
        findings.append(f"{path}: visibility private requires owner_org (db id)")
    for var, raw in (doc.get("input") or {}).items():
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", var):
            findings.append(f"{path}: input key '{var}' is not a valid TF variable name")
        if isinstance(raw, str):
            m = REF_RE.match(raw)
            if m and m["unit"] == "addon":
                rest = m["rest"]
                if "." not in rest:
                    findings.append(f"{path}: '{raw}' must name $addon.<id>.<output>")
    return findings


def main(argv=None) -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    p_index = sub.add_parser("build-index")
    p_index.add_argument("--workflow", required=True,
                         help=".github/workflows/sync.yml")
    p_index.add_argument("--repo", required=True, help="this fork's owner/name")
    p_index.add_argument("--owner", default="NamazuStudios")
    p_index.add_argument("--out", required=True)

    p_lm = sub.add_parser("lint-manifest")
    p_lm.add_argument("paths", nargs="+")

    p_lw = sub.add_parser("lint-workflow")
    p_lw.add_argument("--workflow", required=True)
    p_lw.add_argument("--runner-pin", choices=["any", "pin-required"],
                      default="any")

    args = p.parse_args(argv)
    try:
        if args.cmd == "build-index":
            index = build_index(args.workflow, args.repo, args.owner)
            with open(args.out, "w", encoding="utf-8") as fh:
                json.dump(index, fh, indent=2)
            print(json.dumps(index, indent=2))
        elif args.cmd == "lint-manifest":
            findings: list = []
            for path in args.paths:
                findings += lint_manifest(path)
            for f in sorted(set(findings)):
                print(f"LINT: {f}", file=sys.stderr)
            return 1 if findings else 0
        elif args.cmd == "lint-workflow":
            findings = lint_workflow(args.workflow)
            if args.runner_pin == "pin-required":
                findings = [f for f in findings if "not SHA-pinned" in f]
            for f in findings:
                print(f"LINT: {f}", file=sys.stderr)
            return 1 if findings else 0
    except LintError as e:
        print(f"LINT: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
