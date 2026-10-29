"""Keep the runtime UI on native DMS controls and theme-derived dimensions."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = [ROOT / "CalDAVTasks.qml", ROOT / "Settings.qml", *sorted((ROOT / "UI").glob("*.qml"))]


class UIStandardsTests(unittest.TestCase):
    def test_native_list_and_toggle(self):
        self.assertRegex((ROOT / "CalDAVTasks.qml").read_text(), r"\bDankListView\s*\{")
        self.assertRegex((ROOT / "Settings.qml").read_text(), r"\bDankToggle\s*\{")

    def test_no_raw_controls_or_attached_tooltips(self):
        pattern = r"\b(?:CheckBox|ListView|ScrollBar|ToolTip)\s*\{|\bToolTip\."
        for path in RUNTIME:
            with self.subTest(file=path.name):
                self.assertIsNone(re.search(pattern, path.read_text()))

    def test_no_fixed_pixel_layout_dimensions(self):
        # Borders can remain one device-independent pixel. Counts, timeouts,
        # opacity and dimensionless theme multipliers are not layout constants.
        pattern = r"(?<![\w.])(?:width|height|implicitWidth|implicitHeight|size)\s*:\s*\d"
        for path in RUNTIME:
            with self.subTest(file=path.name):
                self.assertIsNone(re.search(pattern, path.read_text()))


if __name__ == "__main__":
    unittest.main()
