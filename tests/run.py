"""Runs the plugin's pure modules under the standalone `luau` CLI.

Each module in src/ is wrapped in a function that receives a fake `script` (so
`require(script.Parent.X)` works) and bundled together with Roblox mocks and the test cases.
"""

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULES = {
    "Easing": "Easing.lua",
    "Sampler": "Sampler.lua",
    "RigPose": "RigPose.lua",
    "SaveReader": "SaveReader.lua",
    "Exporter": "Exporter.lua",
    "Formatter": "Formatter.lua",
    "MoonHook": "MoonHook.lua",
    "Packager": "Packager.lua",
    "Sequence": "Templates/Sequence.luau",
    "Widget": "Widget.lua",
}


def wrap(name: str) -> str:
    source = (ROOT / "src" / MODULES[name]).read_text(encoding="utf-8")
    # `export type` is only legal at a module's top level, and these become function bodies.
    source = re.sub(r"^export type", "type", source, flags=re.MULTILINE)
    return f'__define("{name}", function(script, require)\n{source}\nend)\n'


def main() -> int:
    tests = ROOT / "tests"
    bundle = "\n".join(
        [
            (tests / "mocks.luau").read_text(encoding="utf-8"),
            *(wrap(name) for name in MODULES),
            (tests / "tests.luau").read_text(encoding="utf-8"),
        ]
    )

    out = tests / "_bundle.luau"
    out.write_text(bundle, encoding="utf-8")
    return subprocess.run(["luau", str(out)]).returncode


if __name__ == "__main__":
    sys.exit(main())
