#!/usr/bin/env python3
"""
Post-processes USDZ packages produced by UsdzConverter, converting their ASCII
(.usda) default layer to a binary (.usdc, "crate") layer in place. Crate layers
are smaller and load faster, and some USDZ consumers (e.g. ARKit Quick Look)
require a crate-encoded default layer rather than plain text.

Usage:
    pip install usd-core
    python usdz_to_crate.py model.usdz [more.usdz ...]
"""

import argparse
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

from pxr import Sdf


def convert(usdz_path: Path) -> None:
    with zipfile.ZipFile(usdz_path) as archive:
        names = archive.namelist()
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            archive.extractall(tmp_dir)

            # Preserve the archive's entry order: USDZ requires the default layer to
            # remain the first entry, so only its name/extension is swapped in place.
            entries = []
            for name in names:
                extracted_path = tmp_dir / name
                if extracted_path.suffix == ".usda":
                    layer = Sdf.Layer.FindOrOpen(str(extracted_path))
                    if layer is None:
                        raise RuntimeError(f"Failed to parse USD layer '{name}' in {usdz_path}")

                    crate_path = extracted_path.with_suffix(".usdc")
                    if not layer.Export(str(crate_path)):
                        raise RuntimeError(f"Failed to export '{name}' as a crate layer")

                    name = str(Path(name).with_suffix(".usdc"))
                    extracted_path = crate_path

                entries.append((name, extracted_path))

            output_path = usdz_path.with_suffix(usdz_path.suffix + ".tmp")
            with Sdf.ZipFileWriter.CreateNew(str(output_path)) as writer:
                for name, extracted_path in entries:
                    writer.AddFile(str(extracted_path), name)

            shutil.move(output_path, usdz_path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("usdz", nargs="+", type=Path, help="USDZ package(s) to post-process in place")
    args = parser.parse_args()

    for usdz_path in args.usdz:
        print(f"Converting {usdz_path} to a crate-backed USDZ package...")
        convert(usdz_path)

    return 0


if __name__ == "__main__":
    sys.exit(main())
