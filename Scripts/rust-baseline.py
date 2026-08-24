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
    out = []
    for x in xs:
        for e in es:
            app = e["expectedApplicability"][cs[x]]
            engine = ENGINE_BY_CLASS[cs[x]][e["id"]]
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
                    "oracle": {"status": "planned"},
                    "mutation": {"status": "planned"},
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
