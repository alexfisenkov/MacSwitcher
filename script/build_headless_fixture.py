#!/usr/bin/env python3
"""Build a no-window AppKit/AX fixture. Does not install, launch, or change settings."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.expanduser().absolute()
    if output.is_symlink() or output.exists():
        parser.error('Use a new output path; existing files are never overwritten')
    output = output.resolve()
    for installed in (Path('/Applications'), Path.home() / 'Applications'):
        if output == installed or installed in output.parents:
            parser.error('Headless fixture cannot be installed in Applications')
    output.parent.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / 'script/fixtures/HeadlessNativeFixture.swift'] + [
        ROOT / 'macos/Sources/RuSwitcher' / filename for filename in
        ('NativeFieldEditPlan.swift', 'VerifiedNativeFieldEditor.swift',
         'NativeTextEventPackets.swift', 'CombinedShiftUnicode.swift', 'NativeFocusRevalidation.swift')]
    with tempfile.TemporaryDirectory(prefix='macswitcher-headless-') as temporary:
        binary = Path(temporary) / 'HeadlessNativeFixture'
        subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '6',
                        '-O', '-parse-as-library', *map(str, sources), '-framework', 'AppKit',
                        '-framework', 'ApplicationServices', '-o', str(binary)], check=True)
        # O_EXCL prevents overwriting a path created concurrently.
        with output.open('xb') as destination:
            destination.write(binary.read_bytes())
        output.chmod(0o700)
    print(json.dumps({'binary': str(output), 'launched': False,
                      'scope': 'owned-background-AppKit-and-cross-process-AX-only',
                      'sources': [{'path': str(source.relative_to(ROOT)),
                                   'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
                                  for source in sources]}))


if __name__ == '__main__':
    main()
