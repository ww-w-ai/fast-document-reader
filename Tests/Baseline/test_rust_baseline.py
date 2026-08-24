import importlib.util
import copy
import io
import json
import tempfile
import unittest
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "baseline", Path(__file__).parents[2] / "Scripts/rust-baseline.py"
)
baseline = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(baseline)


class BaselineTests(unittest.TestCase):
    def test_registered_dimensions_are_closed(self):
        extensions, classes = baseline.extensions()
        self.assertEqual(70, len(extensions))
        self.assertEqual(baseline.CLASSES, set(classes.values()))
        self.assertEqual(7, len(baseline.entries()))

    def test_manifest_maps_every_registered_extension(self):
        _document, sources, mapping = baseline.manifest(check=False)
        self.assertEqual(6, len(sources))
        self.assertEqual(set(baseline.extensions()[0]), set(mapping))

    def test_manifest_rejects_duplicate_source_class(self):
        document, _sources, _mapping = baseline.manifest(check=False)
        malformed = copy.deepcopy(document)
        malformed["sources"][5]["class"] = "hwp"
        with self.assertRaises(baseline.Error):
            baseline.validate_manifest_data(malformed, check=False)

    def test_manifest_rejects_extension_mapped_to_wrong_class(self):
        document, _sources, _mapping = baseline.manifest(check=False)
        malformed = copy.deepcopy(document)
        malformed["extensionMap"]["md"] = "plain-text"
        with self.assertRaises(baseline.Error):
            baseline.validate_manifest_data(malformed, check=False)

    def test_manifest_rejects_missing_source_reference(self):
        document, _sources, _mapping = baseline.manifest(check=False)
        malformed = copy.deepcopy(document)
        malformed["extensionMap"]["md"] = "missing-source"
        with self.assertRaises(baseline.Error):
            baseline.validate_manifest_data(malformed, check=False)

    def test_manifest_rejects_document_types_extension_drift(self):
        document, _sources, _mapping = baseline.manifest(check=False)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / baseline.DT
            target.parent.mkdir(parents=True)
            source = (baseline.ROOT / baseline.DT).read_text()
            target.write_text(
                source.replace('["md", "markdown"]', '["md", "markdown", "mdx"]')
            )
            with self.assertRaises(baseline.Error):
                baseline.validate_manifest_data(document, root=root, check=False)

    def test_manifest_rejects_unknown_source_kind(self):
        document, _sources, _mapping = baseline.manifest(check=False)
        malformed = copy.deepcopy(document)
        malformed["sources"][0]["kind"] = "download"
        with self.assertRaises(baseline.Error):
            baseline.validate_manifest_data(malformed, check=False)

    def test_manifest_rejects_wrong_rhwp_pin_or_license(self):
        document, _sources, _mapping = baseline.manifest(check=False)
        for field, value in (("immutableRevision", "0" * 40), ("license", "MPL-2.0")):
            malformed = copy.deepcopy(document)
            source = next(s for s in malformed["sources"] if s["id"] == "hwp")
            source[field] = value
            with self.assertRaises(baseline.Error):
                baseline.validate_manifest_data(malformed, check=False)

    def test_rhwp_sources_record_mit_license(self):
        _document, sources, _mapping = baseline.manifest(check=False)
        rhwp = [source for source in sources if source["class"] in {"hwp", "hwpx"}]
        self.assertTrue(all(source["license"] == "MIT" for source in rhwp))
        self.assertTrue(all("MIT" in source["redistribution"] for source in rhwp))

    def test_matrix_has_490_unique_typed_cells(self):
        _document, _sources, mapping = baseline.manifest(check=False)
        cells = baseline.cells(baseline.entries(), mapping)
        self.assertEqual(490, len(cells))
        self.assertEqual(490, len({(c["extension"], c["entryPointId"]) for c in cells}))
        self.assertTrue(all(c["applicability"] in baseline.APPS for c in cells))

    def test_entry_registry_rejects_malformed_contracts(self):
        document = baseline.load(baseline.ROOT / "Tests/Baseline/entry-points.json")
        mutations = []
        duplicate = copy.deepcopy(document)
        duplicate["entryPoints"][1]["id"] = duplicate["entryPoints"][0]["id"]
        mutations.append(duplicate)
        unknown = copy.deepcopy(document)
        unknown["entryPoints"][0]["expectedApplicability"]["markdown"] = "optional"
        mutations.append(unknown)
        missing = copy.deepcopy(document)
        missing["entryPoints"][0]["authorityFile"] = "missing.swift"
        mutations.append(missing)
        for malformed in mutations:
            with self.assertRaises(baseline.Error):
                baseline.validate_entries_data(malformed)

    def test_validate_output_rejects_wrong_canonical_counts(self):
        args = type(
            "Args",
            (),
            {
                "output": "/unused",
                "expect_extensions": 69,
                "expect_entry_points": 7,
                "expect_cells": 490,
                "expect_source_fixtures": 6,
                "expect_variants": 70,
            },
        )()
        with self.assertRaisesRegex(baseline.Error, "canonical EXPECTED"):
            baseline.validate_output(args)

    def test_representative_engine_claims(self):
        _document, _sources, mapping = baseline.manifest(check=False)
        cells = baseline.cells(baseline.entries(), mapping)
        claims = {
            (cell["extension"], cell["entryPointId"]): cell["engineClaim"]
            for cell in cells
        }
        self.assertEqual("mixed", claims[("docx", "gui-open")])
        self.assertEqual("mixed", claims[("odt", "pdf")])
        self.assertEqual("mixed", claims[("docx", "quick-look")])
        self.assertEqual("swift", claims[("hwp", "gui-reload")])
        self.assertEqual("swift", claims[("hwpx", "quick-look")])
        self.assertEqual("rust", claims[("hwp", "extract")])

    def test_odt_mimetype_is_first_and_uncompressed(self):
        with zipfile.ZipFile(io.BytesIO(baseline.zipbytes("odt"))) as archive:
            infos = archive.infolist()
            manifest_xml = archive.read("META-INF/manifest.xml")
        self.assertEqual("mimetype", infos[0].filename)
        self.assertEqual(zipfile.ZIP_STORED, infos[0].compress_type)
        self.assertEqual(
            sorted(info.filename for info in infos[1:]),
            [info.filename for info in infos[1:]],
        )
        manifest = ET.fromstring(manifest_xml)
        namespace = "{urn:oasis:names:tc:opendocument:xmlns:manifest:1.0}"
        declarations = {
            entry.attrib[f"{namespace}full-path"]: entry.attrib[
                f"{namespace}media-type"
            ]
            for entry in manifest
        }
        self.assertEqual("text/xml", declarations["content.xml"])

    def test_docx_relationship_targets_main_document(self):
        with zipfile.ZipFile(io.BytesIO(baseline.zipbytes("docx"))) as archive:
            relationship_xml = archive.read("_rels/.rels")
            content_types_xml = archive.read("[Content_Types].xml")
            self.assertIn("word/document.xml", archive.namelist())
        root = ET.fromstring(relationship_xml)
        relationship = next(iter(root))
        self.assertEqual("word/document.xml", relationship.attrib["Target"])
        self.assertTrue(relationship.attrib["Type"].endswith("/officeDocument"))
        content_types = ET.fromstring(content_types_xml)
        rels_default = next(
            declaration
            for declaration in content_types
            if declaration.tag.endswith("Default")
            and declaration.attrib.get("Extension") == "rels"
        )
        self.assertEqual(
            "application/vnd.openxmlformats-package.relationships+xml",
            rels_default.attrib["ContentType"],
        )

    def test_output_rejects_coordinated_manifest_and_variant_tamper(self):
        with tempfile.TemporaryDirectory() as directory:
            args = type("Args", (), {"output": directory})()
            baseline.materialize(args)
            manifest_path = Path(directory) / "manifest.json"
            document = json.loads(manifest_path.read_text())
            tampered = b"coordinated tamper\n"
            plain_source = next(
                source for source in document["sources"] if source["id"] == "plain-text"
            )
            plain_source["expectedSha256"] = baseline.hashlib.sha256(
                tampered
            ).hexdigest()
            manifest_path.write_text(json.dumps(document))
            (Path(directory) / "variants" / "baseline.txt").write_bytes(tampered)
            with self.assertRaisesRegex(baseline.Error, "canonical"):
                baseline.inspect(directory)

    def test_probe_verifier_rejects_wrong_name(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cargo.log"
            path.write_text("test wanted ... ignored\n")
            args = type(
                "Args",
                (),
                {"input": str(path), "expect_ignored": 1, "expect_name": "other"},
            )()
            with self.assertRaises(baseline.Error):
                baseline.probe(args)

    def test_probe_verifier_rejects_failed_cargo_result(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cargo.log"
            path.write_text(
                "test wanted ... ignored\n"
                "test result: FAILED. 0 passed; 1 failed; 1 ignored;\n"
            )
            with self.assertRaises(baseline.Error):
                baseline.verify_probe_log(path, 1, "wanted")

    def test_summary_requires_both_exact_probe_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            extract = Path(directory) / "extract.log"
            export = Path(directory) / "export.log"
            extract.write_text(
                "test extract_matches_the_swift_reader_across_a_real_corpus ... ignored\n"
            )
            export.write_text("test wrong_name ... ignored\n")
            args = type(
                "Args",
                (),
                {
                    "output": directory,
                    "json": None,
                    "extract_probe_log": str(extract),
                    "export_probe_log": str(export),
                },
            )()
            with self.assertRaises(baseline.Error):
                baseline.summary(args)


if __name__ == "__main__":
    unittest.main()
