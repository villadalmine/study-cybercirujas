"""lab.yaml: load, validate against the v2 JSON Schema, and normalize.

Normalizing is the "automatic migration": a v1 file (the 548 generated before
the runner existed) is read unchanged and the v2 fields the runner needs are
inferred from the script itself — never written back unless asked
(`study-lab migrate --write`). Nothing here runs anything; it is pure reading,
so it is safe on untrusted labs from other repositories.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml

SCHEMA_PATH = Path(__file__).parent / "schema" / "lab.v2.schema.json"
SCHEMA_VERSION = 2

# Verbs seen in the existing scripts, in order of preference per action.
VERBS = {
    "break": ["break", "--break"],
    "verify": ["verify", "check", "--verify", "--check"],
    "cleanup": ["cleanup", "clean", "--cleanup", "--clean", "reset", "restore", "--restore"],
}

# Every script asks "is this a disposable machine?" in its own way. Inside the
# runner it always is, so the known variables are set for every mode.
DEFAULT_ENV = {
    "I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM": "yes",
    "LAB_DISPOSABLE": "yes",
    "STUDY_LAB": "1",
}

DEFAULTS = {
    "kind": {"ram_mb": 3072, "cpus": 2, "up": 600},
    "k3s": {"ram_mb": 2048, "cpus": 2, "up": 300},
    "linux": {"ram_mb": 512, "cpus": 1, "up": 60},
}


class SpecError(Exception):
    pass


@dataclass
class Lab:
    directory: Path
    raw: dict
    spec: dict  # normalized (v2 view)
    origin: str  # curated | community | local
    source: str  # human-readable where it came from
    errors: list[str] = field(default_factory=list)  # schema errors
    contract: dict = field(default_factory=dict)  # action -> args or None
    cli_args: list = field(default_factory=list)  # how the user named it, for the hints printed

    @property
    def lab_id(self) -> str:
        return f"{self.spec.get('cert', 'lab')}-{self.spec.get('topic', 'x')}"

    @property
    def contract_ok(self) -> bool:
        return all(self.contract.get(a) is not None for a in ("break", "verify", "cleanup"))

    @property
    def verified(self) -> bool:
        return bool((self.spec.get("verified") or {}).get("status"))


def load_schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def schema_errors(data) -> list[str]:
    try:
        import jsonschema
    except ImportError as exc:  # pragma: no cover - depends on the environment
        raise SpecError("jsonschema is not installed: pip install 'teach-plat[lab]' (or pip install jsonschema)") from exc
    validator = jsonschema.Draft202012Validator(load_schema())
    out = []
    for err in sorted(validator.iter_errors(data), key=lambda e: list(e.path)):
        where = "/".join(str(p) for p in err.path) or "(root)"
        out.append(f"{where}: {err.message}")
    return out


def _verb_present(script: str, verb: str) -> bool:
    v = re.escape(verb)
    patterns = [
        rf"(^|[\s|(]){v}\)",  # case arm:  verify)  |verify)
        rf"==\s*[\"']{v}[\"']",  # [[ "$1" == "verify" ]]
        rf"[\"']{v}[\"']\s*\)",  # "verify")
    ]
    return any(re.search(p, script, re.M) for p in patterns)


def infer_contract(script: str) -> dict:
    """action -> args list, or None when the script does not offer it."""
    found = {}
    for action, verbs in VERBS.items():
        found[action] = next(([v] for v in verbs if _verb_present(script, v)), None)
    if found["break"] is None:
        # Most scripts break when called without arguments; only claim it when
        # no other verb is required to reach the breaking code.
        found["break"] = []
    return found


def normalize(raw: dict, script_text: str | None) -> tuple[dict, dict]:
    spec = dict(raw)
    spec.setdefault("schema_version", 1)
    spec.setdefault("script", (raw.get("setup") or ["break_fix.sh"])[0])
    if "requires" not in spec:
        spec["requires"] = "kind" if script_text and "kubectl" in script_text else "linux"
    spec.setdefault("run_in", "runner")
    spec.setdefault("run_as", "root")
    fam = DEFAULTS.get(spec["requires"], DEFAULTS["linux"])
    limits = dict(spec.get("limits") or {})
    if spec["requires"] == "linux":
        vm = ((raw.get("resources") or {}).get("vms") or [{}])[0]
        limits.setdefault("ram_mb", vm.get("ram_mb", fam["ram_mb"]))
        limits.setdefault("cpus", vm.get("cpus", fam["cpus"]))
    limits.setdefault("ram_mb", fam["ram_mb"])
    limits.setdefault("cpus", fam["cpus"])
    spec["limits"] = limits
    timeout = {"up": fam["up"], "break": 300, "verify": 120, "cleanup": 300}
    timeout.update(spec.get("timeout") or {})
    spec["timeout"] = timeout
    env = dict(DEFAULT_ENV)
    env.update(spec.get("env") or {})
    spec["env"] = env

    inferred = infer_contract(script_text or "")
    declared = spec.get("modes") or {}
    contract = {}
    for action in ("break", "verify", "cleanup"):
        if action in declared:
            contract[action] = list(declared[action].get("args", []))
        else:
            contract[action] = inferred[action]
    return spec, contract


def load(directory: Path, origin: str = "local", source: str | None = None) -> Lab:
    directory = Path(directory)
    spec_file = directory / "lab.yaml"
    if not spec_file.is_file():
        raise SpecError(f"no lab.yaml in {directory}")
    try:
        raw = yaml.safe_load(spec_file.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise SpecError(f"{spec_file}: invalid YAML: {exc}") from exc
    if not isinstance(raw, dict):
        raise SpecError(f"{spec_file}: must be a mapping")
    errors = schema_errors(raw)
    script_name = raw.get("script") or (raw.get("setup") or ["break_fix.sh"])[0]
    script_path = (directory / script_name).resolve()
    script_text = None
    if directory.resolve() not in script_path.parents:
        errors.append(f"script: {script_name} escapes the lab directory")
    elif script_path.is_file():
        script_text = script_path.read_text(encoding="utf-8", errors="replace")
        if b"\r\n" in script_path.read_bytes():
            errors.append(f"script: {script_name} has CRLF line endings (bash fails on them; add '*.sh eol=lf' to .gitattributes)")
    else:
        errors.append(f"script: {script_name} does not exist")
    if isinstance(raw.get("cert"), (int, float)) or isinstance(raw.get("topic"), (int, float)):
        errors.append("topic/cert must be strings (quote them: topic: '1.1')")
    spec, contract = normalize(raw, script_text)
    lab = Lab(directory=directory, raw=raw, spec=spec, origin=origin,
              source=source or str(directory), errors=errors, contract=contract)
    return lab


def migrate(lab: Lab) -> dict:
    """The v2 file a v1 lab would have: explicit requires and modes, nothing guessed silently."""
    out = dict(lab.raw)
    out["schema_version"] = SCHEMA_VERSION
    out.setdefault("requires", lab.spec["requires"])
    modes = dict(out.get("modes") or {})
    for action in ("break", "verify", "cleanup"):
        if action not in modes and lab.contract.get(action) is not None:
            modes[action] = {"args": lab.contract[action]}
    out["modes"] = modes
    out.setdefault("origin", {"kind": "curated" if lab.origin == "curated" else "community"})
    out.setdefault("verified", {"status": False})
    return out
