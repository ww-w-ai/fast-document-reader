import importlib.util
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "hwp_page_break_audit",
    Path(__file__).parents[2] / "Scripts/hwp-page-break-audit.py",
)
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


class HwpPageBreakAuditTests(unittest.TestCase):
    def test_counts_both_declaration_kinds(self):
        lines = [
            "--- 문단 0.2 --- cc=1 [쪽나누기]",
            "--- 문단 1.0 --- cc=1 [구역나누기]",
        ]
        self.assertEqual([(0, 2, "쪽나누기"), (1, 0, "구역나누기")], audit.declarations(lines))

    def test_partial_table_can_be_the_first_item(self):
        lines = [
            "=== 페이지 7 (global_idx=6, section=3, page_num=7) ===",
            "  body_area: x=0 y=0 w=1 h=1",
            "    PartialTable   pi=64 ci=0 rows=0..1",
        ]
        self.assertEqual({(3, 64)}, audit.recorded_page_starts(lines))

    def test_last_page_without_a_known_item_fails_closed(self):
        lines = [
            "=== 페이지 7 (global_idx=6, section=3, page_num=7) ===",
            "    UnknownItem pi=64",
        ]
        with self.assertRaises(RuntimeError):
            audit.recorded_page_starts(lines)


if __name__ == "__main__":
    unittest.main()
