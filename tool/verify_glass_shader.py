#!/usr/bin/env python3
"""Compile every runtime backend and compare actual old/new shader pixels.

Runs headlessly in a disposable Flutter test project; test shaders never enter
the package's shipped assets. The reference is the app's pre-optimization pin.
Requires Flutter on PATH and that reference commit in this Git checkout.
"""

import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile


def run(args, cwd):
    subprocess.run(args, cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", default="5f424525582e6d6bdea13d7d14afd2910d20a79d")
    parser.add_argument("--metal-benchmark", action="store_true",
                        help="Also compare offscreen Metal GPU timings on this Mac")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    flutter = pathlib.Path(shutil.which("flutter")).resolve()
    sdk = flutter.parent.parent
    engine = sdk / "bin/cache/artifacts/engine"
    compilers = list(engine.glob("*/impellerc"))
    if not compilers:
        raise SystemExit("Flutter's cached impellerc is missing; run flutter precache first.")
    compiler = compilers[0]
    include = sdk / "engine/src/flutter/impeller/compiler/shader_lib"
    with tempfile.TemporaryDirectory(prefix="glass-shader-parity-") as directory:
        work = pathlib.Path(directory)
        for name in ("reference", "current"):
            target = work / "shaders" / name
            target.mkdir(parents=True)
            for source in (root / "shaders").iterdir():
                if source.suffix not in (".frag", ".glsl"):
                    continue
                if name == "reference":
                    data = subprocess.check_output(
                        ["git", "show", f"{args.reference}:shaders/{source.name}"], cwd=root
                    )
                    (target / source.name).write_bytes(data)
                else:
                    shutil.copyfile(source, target / source.name)
        current = work / "shaders/current/liquid_glass_render.frag"
        for stage in ("sksl", "runtime-stage-metal", "runtime-stage-vulkan", "runtime-stage-gles", "runtime-stage-gles3"):
            run([
                str(compiler), f"--{stage}", f"--input={current}",
                f"--sl={work / (stage + '.shader')}",
                f"--spirv={work / (stage + '.spirv')}",
                f"--include={include}", f"--include={current.parent}",
            ], work)
            print(f"Compiled {stage}", flush=True)
        (work / "pubspec.yaml").write_text("""name: glass_shader_parity
environment:
  sdk: '>=3.5.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  flutter_test:
    sdk: flutter
flutter:
  shaders:
    - shaders/reference/liquid_glass_render.frag
    - shaders/current/liquid_glass_render.frag
""")
        (work / "test").mkdir()
        shutil.copyfile(root / "tool/shader_parity_test.dart", work / "test/shader_parity_test.dart")
        print(json.dumps({"reference": args.reference, "project": str(work)}), flush=True)
        run([str(flutter), "test", "--reporter=expanded"], work)
        if args.metal_benchmark:
            reference = work / "shaders/reference/liquid_glass_render.frag"
            reference_metal = work / "reference.metal"
            run([str(compiler), "--runtime-stage-metal", f"--input={reference}",
                 f"--sl={reference_metal}", f"--spirv={work / 'reference.spirv'}",
                 f"--include={include}", f"--include={reference.parent}"], work)
            executable = work / "benchmark"
            run(["xcrun", "swiftc", "-O", str(root / "tool/benchmark_glass_shader.swift"),
                 "-o", str(executable)], work)
            run([str(executable), str(reference_metal),
                 str(work / "runtime-stage-metal.shader")], work)


if __name__ == "__main__":
    main()
