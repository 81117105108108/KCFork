"""Exercise the real runner with isolated temporary test suites."""

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
ZUNE = os.environ.get("ZUNE", "zune")


def run(directory: Path, *args: str) -> int:
    return subprocess.run(
        [ZUNE, "run", str(ROOT / "tests/run_tests.luau"), "--test-dir", str(directory), *args],
        cwd=ROOT, check=False, timeout=60,
    ).returncode


with tempfile.TemporaryDirectory(prefix="kinemium-runner-") as temporary:
    suite = Path(temporary)
    assert run(suite) != 0, "empty discovery must fail"
    (suite / "a.luau").write_text('print("FAIL is only text")\n', encoding="utf-8")
    (suite / "run_tests.luau").write_text('error("self recursion")\n', encoding="utf-8")
    (suite / "perf_benchmark.luau").write_text('error("benchmark selected")\n', encoding="utf-8")
    assert run(suite) == 0, "default must exclude runner and benchmarks"
    assert run(suite, "--benchmarks") != 0, "explicit benchmark failure must propagate"
    (suite / "a.luau").write_text('print("PASS")\nzune.process.exit(7)\n', encoding="utf-8")
    (suite / "z.py").write_text('from pathlib import Path\nPath(__file__).with_suffix(".ran").touch()\n', encoding="utf-8")
    assert run(suite) != 0, "child exit 7 must fail despite PASS output"
    assert (suite / "z.ran").is_file(), "runner must continue after a failed child"
    (suite / "a.luau").write_text('error("intentional assertion failure")\n', encoding="utf-8")
    assert run(suite) != 0, "uncaught Luau errors must fail"
print("PASS runner exit status, continuation, empty discovery, and exclusions")
