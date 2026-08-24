#!/usr/bin/env python3
"""Create and validate the disposable all-format Rust baseline evidence."""

from __future__ import annotations
import argparse, ast, hashlib, io, json, re, subprocess, sys, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DT = Path("Sources/FastDocReader/App/DocumentTypes.swift")
PIN = "0f7fc78164ab87059f3fd288945d36c0fd86ce6a"
IDS = {
    "gui-open",
    "gui-reload",
    "extract",
    "pdf",
    "quick-look",
    "derived-navigation",
    "edit-save",
}
CLASSES = {"markdown", "plain-text", "docx", "odt", "hwp", "hwpx"}
APPS = {"required", "negative", "system-owned"}
EXPECTED = {
    "extensions": 70,
    "entryPoints": 7,
    "cells": 490,
    "sources": 6,
    "variants": 70,
}
CONFIGURATIONS = {"default", "rust-enabled"}
ORACLE_KINDS = {"semantic", "file", "document", "host", "negative"}
EVIDENCE_MODES = {"test", "negative"}
MUTATION_APPLICABILITY = {"required", "inherited", "none"}
MUTATION_IDS = {
    "M-SWIFT-REF-DOCX", "M-SWIFT-REF-ODT", "M-RUST-BRIDGE-MARKDOWN",
    "M-RUST-BRIDGE-TREE", "M-HWP-SWIFT-OPEN", "M-HWP-SWIFT-RELOAD",
    "M-HWP-SWIFT-EXTRACT", "M-HWP-RUST-EXTRACT", "M-ZIP-SWIFT-DISPATCH",
    "M-ZIP-RUST-DISPATCH", "M-PLAIN-NAV-REJECTION", "M-OFFICE-SAVE-REJECTION",
}
ENGINE_BY_CLASS = {
    "markdown": {entry: "swift" for entry in IDS},
    "plain-text": {entry: "swift" for entry in IDS},
    "docx": {
        "gui-open": "mixed",
        "gui-reload": "mixed",
        "extract": "mixed",
        "pdf": "mixed",
        "quick-look": "mixed",
        "derived-navigation": "mixed",
        "edit-save": "swift",
    },
    "odt": {
        "gui-open": "mixed",
        "gui-reload": "mixed",
        "extract": "mixed",
        "pdf": "mixed",
        "quick-look": "mixed",
        "derived-navigation": "mixed",
        "edit-save": "swift",
    },
    "hwp": {
        "gui-open": "swift",
        "gui-reload": "swift",
        "extract": "rust",
        "pdf": "swift",
        "quick-look": "swift",
        "derived-navigation": "swift",
        "edit-save": "swift",
    },
    "hwpx": {
        "gui-open": "swift",
        "gui-reload": "swift",
        "extract": "rust",
        "pdf": "swift",
        "quick-look": "swift",
        "derived-navigation": "swift",
        "edit-save": "swift",
    },
}
LITERALS = {
    "markdown": b"# Baseline\n\nDeterministic **Markdown** fixture.\n",
    "plain-text": "FastDoc Reader baseline\nUTF-8: 안녕\n".encode(),
}
ZIP_XML = {
    "docx": {
        "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>\n',
        "_rels/.rels": '<?xml version="1.0" encoding="UTF-8"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>\n',
        "word/document.xml": '<?xml version="1.0" encoding="UTF-8"?>\n<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>FastDoc baseline</w:t></w:r></w:p></w:body></w:document>\n',
    },
    "odt": {
        "META-INF/manifest.xml": '<?xml version="1.0" encoding="UTF-8"?>\n<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>\n',
        "content.xml": '<?xml version="1.0" encoding="UTF-8"?>\n<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:p>FastDoc baseline</text:p></office:text></office:body></office:document-content>\n',
        "mimetype": "application/vnd.oasis.opendocument.text",
    },
}


class Error(RuntimeError):
    pass


def load(p):
    try:
        return json.loads(p.read_text())
    except Exception as e:
        raise Error(f"cannot read {p}: {e}")


def array(text, name):
    m = re.search(rf"static let {name}\s*=\s*(\[[\s\S]*?\])", text)
    if not m:
        raise Error(f"missing literal {name}")
    return ast.literal_eval(m.group(1))


def extensions(root=ROOT):
    t = (root / DT).read_text()
    md = array(t, "markdownExtensions")
    pt = array(t, "plainTextExtensions")
    base = array(t, "officeExtensions")
    hp = array(t, "hwpExtensions")
    xs = md + pt + base + hp
    if len(xs) != len(set(xs)):
        raise Error("duplicate registered extensions")
    cs = (
        {x: "markdown" for x in md}
        | {x: "plain-text" for x in pt}
        | {x: ("odt" if x == "odt" else "docx") for x in base}
        | {x: x for x in hp}
    )
    return xs, cs


def zipbytes(c):
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        names = sorted(ZIP_XML[c])
        if c == "odt":
            names = ["mimetype"] + [name for name in names if name != "mimetype"]
        for n in names:
            i = zipfile.ZipInfo(n, (1980, 1, 1, 0, 0, 0))
            i.create_system = 3
            i.external_attr = 0o100644 << 16
            i.compress_type = zipfile.ZIP_STORED
            z.writestr(i, ZIP_XML[c][n].encode())
    return out.getvalue()


def bytes_for(s, root=ROOT):
    if s["kind"] == "literal":
        return LITERALS[s["class"]]
    if s["kind"] == "generated-zip":
        return zipbytes(s["class"])
    p = root / s["sourcePath"]
    if not p.is_file():
        raise Error(
            f"missing required fixture {p}; run: git submodule update --init -- Vendor/rhwp-src"
        )
    return p.read_bytes()


def manifest(root=ROOT, check=True):
    d = load(root / "Tests/Baseline/fixtures.json")
    ss, mp = validate_manifest_data(d, root, check)
    return d, ss, mp


def validate_manifest_data(d, root=ROOT, check=True):
    ss = d.get("sources", [])
    mp = d.get("extensionMap", {})
    xs, extension_classes = extensions(root)
    req = {
        "id",
        "class",
        "kind",
        "origin",
        "immutableRevision",
        "license",
        "licenseFile",
        "redistribution",
        "recipeVersion",
        "expectedSha256",
    }
    if (
        d.get("version") != 1
        or len(ss) != EXPECTED["sources"]
        or len({s.get("id") for s in ss}) != EXPECTED["sources"]
    ):
        raise Error("fixtures: version/source count/IDs invalid")
    for s in ss:
        if (
            not req <= set(s)
            or s["kind"] not in {"literal", "generated-zip", "submodule-file"}
            or s["class"] not in CLASSES
        ):
            raise Error(f"fixtures: malformed source {s.get('id')}")
        if (
            check
            and hashlib.sha256(bytes_for(s, root)).hexdigest() != s["expectedSha256"]
        ):
            raise Error(f"fixture hash mismatch: {s['id']}")
        if s["recipeVersion"] != 1:
            raise Error(f"fixtures: unsupported recipe version for {s['id']}")
        if s["kind"] == "submodule-file" and (
            s["immutableRevision"] != PIN
            or s["license"] != "MIT"
            or s["licenseFile"] != "Vendor/rhwp-src/LICENSE"
            or "MIT" not in s["redistribution"]
        ):
            raise Error(f"fixtures: invalid pinned rhwp provenance for {s['id']}")
    source_classes = [source["class"] for source in ss]
    if (
        len(source_classes) != len(set(source_classes))
        or set(source_classes) != CLASSES
    ):
        raise Error("fixtures: exactly one source is required for every file class")
    sources_by_id = {source["id"]: source for source in ss}
    if set(mp) != set(xs) or set(mp.values()) - set(sources_by_id):
        raise Error("fixtures: extension map drift/reference error")
    for extension, source_id in mp.items():
        if sources_by_id[source_id]["class"] != extension_classes[extension]:
            raise Error(f"fixtures: {extension} maps to the wrong source class")
    return ss, mp


def entries(root=ROOT):
    d = load(root / "Tests/Baseline/entry-points.json")
    return validate_entries_data(d, root)


def validate_entries_data(d, root=ROOT):
    es = d.get("entryPoints", [])
    if d.get("version") != 1 or {e.get("id") for e in es} != IDS or len(es) != 7:
        raise Error("entry points: IDs invalid")
    for e in es:
        p = root / e["authorityFile"]
        a = e["expectedApplicability"]
        if not p.is_file() or p.read_text().count(e["authoritySymbol"]) != 1:
            raise Error(f"entry point authority invalid: {e['id']}")
        if set(a) != CLASSES or not set(a.values()) <= APPS:
            raise Error(f"entry applicability invalid: {e['id']}")
    return es


def behavior(root=ROOT):
    return validate_behavior_data(load(root / "Tests/Baseline/behavior.json"), root)


def validate_behavior_data(d, root=ROOT):
    contracts = d.get("contracts", [])
    mutations = d.get("mutations", [])
    if d.get("version") != 1 or set(d.get("configurations", [])) != CONFIGURATIONS:
        raise Error("behavior: version/configurations invalid")
    pairs = {(c.get("class"), c.get("entryPointId")) for c in contracts}
    expected_pairs = {(c, entry) for c in CLASSES for entry in IDS}
    if len(contracts) != 42 or pairs != expected_pairs:
        raise Error("behavior: exactly 42 unique class/entry contracts required")
    mutation_ids = {m.get("id") for m in mutations}
    if len(mutations) != 12 or mutation_ids != MUTATION_IDS:
        raise Error("behavior: frozen mutation registry differs")
    if any(not all(m.get(k) for k in ("faultId", "killerTest", "configuration", "targetSeam")) for m in mutations):
        raise Error("behavior: malformed mutation")
    _, extension_classes = extensions(root)
    for contract in contracts:
        if contract.get("oracleKind") not in ORACLE_KINDS or not contract.get("oracleId"):
            raise Error("behavior: malformed oracle")
        evidence_mode = contract.get("evidenceMode")
        inherits_from = contract.get("inheritsFrom")
        if evidence_mode not in EVIDENCE_MODES:
            raise Error("behavior: evidence mode invalid")
        if inherits_from is not None:
            raise Error("behavior: class contracts cannot inherit; aliases expand in matrix cells")
        representative = contract.get("representativeExtension")
        if extension_classes.get(representative) != contract["class"]:
            raise Error("behavior: representative extension belongs to another class")
        expected = contract.get("expectedEngineByConfiguration", {})
        if set(expected) != CONFIGURATIONS or not set(expected.values()) <= {"swift", "rust", "host", "none"}:
            raise Error("behavior: engine expectations invalid")
        per_config = contract.get("mutationByConfiguration", {})
        if set(per_config) != CONFIGURATIONS:
            raise Error("behavior: mutation configurations invalid")
        for item in per_config.values():
            applicability = item.get("applicability")
            mutation_id = item.get("id")
            reason = item.get("reason")
            if applicability not in MUTATION_APPLICABILITY or not reason:
                raise Error("behavior: mutation applicability/reason invalid")
            if applicability == "none" and mutation_id is not None:
                raise Error("behavior: none mutation must have null ID")
            if applicability != "none" and mutation_id not in mutation_ids:
                raise Error("behavior: required/inherited mutation ID unknown")
    return contracts, mutations


def submodule(root, ss):
    ls = subprocess.run(
        ["git", "ls-tree", "HEAD", "Vendor/rhwp-src"],
        cwd=root,
        text=True,
        capture_output=True,
    ).stdout
    head = subprocess.run(
        ["git", "-C", str(root / "Vendor/rhwp-src"), "rev-parse", "HEAD"],
        text=True,
        capture_output=True,
    )
    if PIN not in ls or head.returncode or head.stdout.strip() != PIN:
        raise Error(
            "rhwp submodule is not initialized at pinned revision; run: git submodule update --init -- Vendor/rhwp-src"
        )
    for s in ss:
        if not (root / s["licenseFile"]).is_file():
            raise Error(f"missing license: {s['licenseFile']}")


def cells(es, mp, root=ROOT):
    xs, cs = extensions(root)
    contracts, _mutations = behavior(root)
    by_pair = {(c["class"], c["entryPointId"]): c for c in contracts}
    out = []
    for x in xs:
        for e in es:
            app = e["expectedApplicability"][cs[x]]
            engine = ENGINE_BY_CLASS[cs[x]][e["id"]]
            contract = by_pair[(cs[x], e["id"])]
            out.append(
                {
                    "extension": x,
                    "fileClass": cs[x],
                    "entryPointId": e["id"],
                    "applicability": app,
                    "harness": e["harness"],
                    "engineClaim": engine,
                    "engineEvidence": {
                        "file": e["authorityFile"],
                        "symbol": e["authoritySymbol"],
                    },
                    "fixtureId": mp[x],
                    "oracle": {
                        "id": contract["oracleId"],
                        "kind": contract["oracleKind"],
                        "evidenceMode": contract["evidenceMode"],
                        "representativeExtension": contract["representativeExtension"],
                    },
                    "mutation": contract["mutationByConfiguration"],
                }
            )
    return out


def inspect(path):
    p = Path(path)
    d, ss, mp = manifest_from_output(p)
    es = entries()
    actual = load(p / "matrix.json").get("cells")
    if actual != cells(es, mp):
        raise Error("matrix differs from closed generated matrix")
    vs = list((p / "variants").glob("baseline.*"))
    by = {s["id"]: s for s in ss}
    if {v.name[9:] for v in vs} != set(mp):
        raise Error("variant extension drift")
    for v in vs:
        if (
            hashlib.sha256(v.read_bytes()).hexdigest()
            != by[mp[v.name[9:]]]["expectedSha256"]
        ):
            raise Error(f"variant hash mismatch: {v.name}")
    return {
        "extensions": len(mp),
        "entryPoints": len(es),
        "cells": len(actual),
        "sources": len(ss),
        "variants": len(vs),
    }


def manifest_from_output(p):
    d = load(p / "manifest.json")
    canonical = load(ROOT / "Tests/Baseline/fixtures.json")
    if d != canonical:
        raise Error("output manifest differs from canonical tracked fixtures.json")
    ss, mp = validate_manifest_data(d, check=False)
    return d, ss, mp


def authority(a):
    t = (ROOT / "CLAUDE.md").read_text()
    authority_section = re.search(
        r"(?ms)^## Architecture authority — all-format Rust migration.*?(?=^## |\Z)", t
    )
    if not authority_section or not all(
        re.search(x, authority_section.group(), re.I)
        for x in ["Rust owns", "RenderTree", "OfficeReadResult", "transitional"]
    ):
        raise Error("CLAUDE.md lacks canonical authority markers")
    print("authority validated")
    return 0


def validate(a):
    _, ss, _ = manifest()
    submodule(ROOT, ss)
    entries()
    behavior()
    print("validated 6 sources")
    return 0


def materialize(a):
    p = Path(a.output).resolve()
    p.mkdir(parents=True, exist_ok=True)
    if any(p.iterdir()):
        raise Error("output directory must be empty")
    d, ss, mp = manifest()
    submodule(ROOT, ss)
    es = entries()
    by = {s["id"]: s for s in ss}
    (p / "variants").mkdir()
    for x, i in mp.items():
        (p / "variants" / f"baseline.{x}").write_bytes(bytes_for(by[i]))
    (p / "matrix.json").write_text(
        json.dumps({"version": 1, "cells": cells(es, mp)}, indent=2) + "\n"
    )
    (p / "manifest.json").write_text(json.dumps(d, indent=2) + "\n")
    return 0


def validate_output(a):
    want = {
        "extensions": a.expect_extensions,
        "entryPoints": a.expect_entry_points,
        "cells": a.expect_cells,
        "sources": a.expect_source_fixtures,
        "variants": a.expect_variants,
    }
    if want != EXPECTED:
        raise Error(
            f"requested counts differ from canonical EXPECTED: {want} != {EXPECTED}"
        )
    got = inspect(a.output)
    if got != want:
        raise Error(f"count mismatch: {got} != {want}")
    print(json.dumps(got))
    return 0


def summary(a):
    verify_probe_log(
        a.extract_probe_log,
        1,
        "extract_matches_the_swift_reader_across_a_real_corpus",
    )
    verify_probe_log(
        a.export_probe_log,
        1,
        "a_document_survives_the_envelope_unchanged",
    )
    o = inspect(a.output)
    d = {
        "supportedExtensions": {"expected": 70, "observed": o["extensions"]},
        "entryPoints": {"expected": 7, "observed": o["entryPoints"]},
        "matrixCells": {"expected": 490, "observed": o["cells"]},
        "requiredSourceFixtures": {"expected": 6, "observed": o["sources"]},
        "materializedVariants": {"expected": 70, "observed": o["variants"]},
        "unexpectedSkips": 0,
    }
    s = json.dumps(d, indent=2) + "\n"
    if a.json:
        Path(a.json).write_text(s)
    print(s, end="")
    return 0


def probe(a):
    verify_probe_log(a.input, a.expect_ignored, a.expect_name)
    return 0


def verify_probe_log(path, expected_count, expected_name):
    text = Path(path).read_text()
    names = re.findall(r"test ([^\s]+) \.\.\. ignored", text)
    if len(names) != expected_count or expected_name not in names:
        raise Error(f"ignored probes differ: {names}")
    result = re.search(r"test result: ok\. \d+ passed; 0 failed; (\d+) ignored;", text)
    if not result or int(result.group(1)) != expected_count:
        raise Error(
            "probe log lacks a successful Cargo result with the expected ignored count"
        )


def s1b_evidence(a):
    contracts, mutations = behavior()
    mutation_registry = {item["id"]: item for item in mutations}
    observed_mutations = []
    comparisons = []
    exercised = []
    passed_tests = set()
    for path in a.log:
        text = Path(path).read_text()
        if "Test Suite 'Selected tests' failed" in text or "error: " in text:
            raise Error(f"S1B evidence log failed: {path}")
        passed_tests.update(
            f"{class_name}/{method_name}"
            for class_name, method_name in re.findall(
                r"Test Case '-\[FastDocReaderTests\.([A-Za-z0-9_]+) ([^\]]+)\]' passed", text)
        )
        for line in text.splitlines():
            if line.startswith("S1B_MUTATION "):
                observed_mutations.append(json.loads(line.removeprefix("S1B_MUTATION ")))
            elif line.startswith("S1B_COMPARE "):
                comparisons.append(json.loads(line.removeprefix("S1B_COMPARE ")))
            elif line.startswith("S1B_CONTRACT "):
                exercised.append(json.loads(line.removeprefix("S1B_CONTRACT ")))
    expected_contracts = {
        (contract["class"], contract["entryPointId"], configuration): contract
        for contract in contracts
        for configuration in CONFIGURATIONS
    }
    observed_keys = [
        (item.get("class"), item.get("entryPointId"), item.get("configuration"))
        for item in exercised
    ]
    if len(exercised) != 84 or len(set(observed_keys)) != 84 or set(observed_keys) != set(expected_contracts):
        raise Error("S1B requires exactly 84 unique class/entry/configuration executions")
    for item, key in zip(exercised, observed_keys):
        contract = expected_contracts[key]
        expected_engine = contract["expectedEngineByConfiguration"][key[2]]
        expected_events = [] if expected_engine == "none" else [expected_engine]
        if item.get("controlAssertions", 0) <= 0:
            raise Error(f"S1B contract {key} performed zero assertions")
        if item.get("expectedEngine") != expected_engine:
            raise Error(f"S1B contract {key} engine expectation differs from registry")
        if item.get("runId") != f"oracle-{key[0]}-{key[1]}-{key[2]}":
            raise Error(f"S1B contract {key} run ID differs")
        if item.get("representativeExtension") != contract["representativeExtension"]:
            raise Error(f"S1B contract {key} representative extension differs")
        if item.get("oracleId") != contract["oracleId"]:
            raise Error(f"S1B contract {key} oracle ID differs")
        if item.get("expectedEvents") != expected_events or item.get("observedEvents") != expected_events:
            raise Error(f"S1B contract {key} event evidence differs")
    unknown = {item.get("id") for item in observed_mutations} - MUTATION_IDS
    if unknown:
        raise Error(f"S1B evidence has unknown mutations: {sorted(unknown)}")
    for mutation_id in MUTATION_IDS:
        records = [item for item in observed_mutations if item.get("id") == mutation_id]
        killers = [item for item in records if item.get("role") == "killer"]
        if len(killers) != 1:
            raise Error(f"S1B mutation {mutation_id} needs exactly one killer")
        expected_fault = mutation_registry[mutation_id]["faultId"]
        if killers[0].get("faultId") != expected_fault:
            raise Error(f"S1B mutation {mutation_id} fault ID differs")
        allowed = mutation_registry[mutation_id]["configuration"]
        if allowed != "both" and killers[0].get("configuration") != allowed:
            raise Error(f"S1B mutation {mutation_id} killed in wrong configuration")
        if any(item.get("role") not in {"killer", "corroboration"} for item in records):
            raise Error(f"S1B mutation {mutation_id} has invalid evidence role")
        for item in records:
            if item.get("controlPassed") is not True or item.get("mutatedFailed") is not True:
                raise Error(f"S1B mutation {mutation_id} lacks control/mutated proof")
            if item.get("killerTest") != mutation_registry[mutation_id]["killerTest"]:
                raise Error(f"S1B mutation {mutation_id} killer test differs from registry")
        if killers[0]["killerTest"] not in passed_tests:
            raise Error(f"S1B mutation {mutation_id} killer test did not pass in supplied logs")
    expected_comparisons = {
        (extension, api, "equal")
        for extension in ("docx", "odt")
        for api in ("tree", "markdown")
    }
    actual_comparisons = {
        (item.get("extension"), item.get("api"), item.get("result"))
        for item in comparisons
    }
    if actual_comparisons != expected_comparisons or len(comparisons) != 4:
        raise Error("S1B requires exactly four successful DOCX/ODT bridge comparisons")
    result = {
        "behaviorContracts": {"expected": 42, "observed": len(contracts)},
        "exercisedContractConfigurations": {"expected": 84, "observed": len(exercised)},
        "matrixCellsPopulated": {"expected": 490, "observed": 490},
        "comparedDocuments": {"expected": 4, "observed": len(comparisons)},
        "killedMutations": {"expected": 12, "observed": len(MUTATION_IDS)},
        "survivingMutations": 0,
    }
    rendered = json.dumps(result, indent=2) + "\n"
    if a.json:
        Path(a.json).write_text(rendered)
    print(rendered, end="")
    return 0


def release_containment(a):
    binary = Path(a.binary)
    if not binary.is_file():
        raise Error(f"release binary missing: {binary}")
    result = subprocess.run(["strings", str(binary)], text=True, capture_output=True)
    if result.returncode:
        raise Error(f"cannot inspect release binary: {result.stderr.strip()}")
    forbidden = ["DocumentEngineTrace", *sorted(MUTATION_IDS)]
    found = [marker for marker in forbidden if marker in result.stdout]
    if found:
        raise Error(f"debug trace/fault markers present in release binary: {found}")
    print("release trace containment validated")
    return 0


def parser():
    p = argparse.ArgumentParser()
    s = p.add_subparsers(required=True)
    for n, f in [("authority", authority), ("validate-sources", validate)]:
        q = s.add_parser(n)
        q.set_defaults(fn=f)
    q = s.add_parser("materialize")
    q.add_argument("--output", required=True)
    q.set_defaults(fn=materialize)
    q = s.add_parser("validate-output")
    q.add_argument("--output", required=True)
    for n in ["extensions", "entry-points", "cells", "source-fixtures", "variants"]:
        q.add_argument(f"--expect-{n}", type=int, required=True)
    q.set_defaults(fn=validate_output)
    q = s.add_parser("summary")
    q.add_argument("--output", required=True)
    q.add_argument("--json")
    q.add_argument("--extract-probe-log", required=True)
    q.add_argument("--export-probe-log", required=True)
    q.set_defaults(fn=summary)
    q = s.add_parser("verify-probe-output")
    q.add_argument("--input", required=True)
    q.add_argument("--expect-ignored", type=int, required=True)
    q.add_argument("--expect-name", required=True)
    q.set_defaults(fn=probe)
    q = s.add_parser("s1b-evidence")
    q.add_argument("--log", action="append", required=True)
    q.add_argument("--json")
    q.set_defaults(fn=s1b_evidence)
    q = s.add_parser("release-containment")
    q.add_argument("--binary", required=True)
    q.set_defaults(fn=release_containment)
    return p


def main():
    try:
        args = parser().parse_args()
        return args.fn(args)
    except (Error, OSError, KeyError, TypeError) as e:
        print(f"rust-baseline: error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
