"""Validate exports from an explicitly supplied built library, never a fallback."""

import argparse
import ctypes
from pathlib import Path
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    args = parser.parse_args()
    try:
        path = args.library.resolve(strict=True)
        library = ctypes.CDLL(str(path))
        getattr(library, "JPH_BodyInterface_GetBulkTransforms")
    except (OSError, AttributeError) as error:
        print(f"FFI validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified JPH_BodyInterface_GetBulkTransforms in {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
