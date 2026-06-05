import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
ENGINE = REPO / "plugins/code-review-suite/bin/housekeeper-freshness"


def load_engine():
    spec = importlib.util.spec_from_file_location("housekeeper_freshness", ENGINE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ChassisTest(unittest.TestCase):
    def test_empty_inputs_emit_empty_array(self):
        with tempfile.TemporaryDirectory() as d:
            files = pathlib.Path(d) / "files.txt"
            lines = pathlib.Path(d) / "lines.txt"
            files.write_text("")
            lines.write_text("Changed lines:\n")
            out = subprocess.run(
                [sys.executable, str(ENGINE),
                 "--root", d,
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines)],
                capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(out.stdout), [])


if __name__ == "__main__":
    unittest.main()
