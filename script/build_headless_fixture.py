#!/usr/bin/env python3
"""Build a no-window AppKit/AX fixture. Does not install, launch, or change settings."""
import argparse
import hashlib
import json
import os
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
    # RuntimeDiagnostics records this production value type. Compile its exact
    # declarations without pulling in the unrelated live editing dependencies.
    diagnostic_types = ROOT / 'macos/Sources/RuSwitcher/Editing/CombinedShiftEditing.swift'
    diagnostics = ROOT / 'macos/Sources/RuSwitcher/RuntimeDiagnostics.swift'
    captured = {source: source.read_bytes() for source in [*sources, diagnostic_types, diagnostics]}
    editing_source = captured[diagnostic_types].decode('utf-8')
    boundary = '\n@MainActor\nenum CombinedShiftEditing {'
    if editing_source.count(boundary) != 1:
        parser.error('Cannot locate production diagnostic type declarations')
    diagnostics_source = captured[diagnostics].decode('utf-8')
    capability_boundary = '\n/// Read-only capability inspection'
    if diagnostics_source.count(capability_boundary) != 1:
        parser.error('Cannot locate production runtime diagnostics declarations')
    with tempfile.TemporaryDirectory(prefix='macswitcher-headless-') as temporary:
        snapshot_directory = Path(temporary) / 'Sources'
        snapshot_directory.mkdir()
        for source in sources:
            (snapshot_directory / source.name).write_bytes(captured[source])
        diagnostic_declarations = snapshot_directory / 'CombinedShiftDiagnosticTypes.swift'
        diagnostic_declarations.write_text(editing_source.split(boundary, 1)[0] + '\n')
        runtime_diagnostics = snapshot_directory / 'RuntimeDiagnostics.swift'
        runtime_diagnostics.write_text(diagnostics_source.split(capability_boundary, 1)[0] + '\n')
        binary = Path(temporary) / 'HeadlessNativeFixture'
        subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '6',
                        '-O', '-parse-as-library',
                        *(str(snapshot_directory / source.name) for source in sources),
                        str(diagnostic_declarations),
                        str(runtime_diagnostics),
                        '-framework', 'AppKit',
                        '-framework', 'ApplicationServices', '-o', str(binary)], check=True)
        # O_EXCL prevents overwriting a path created concurrently.
        with output.open('xb') as destination:
            os.fchmod(destination.fileno(), 0o700)
            destination.write(binary.read_bytes())
    print(json.dumps({'binary': str(output), 'launched': False,
                      'scope': 'owned-background-AppKit-and-cross-process-AX-only',
                      'sources': [{'path': str(source.relative_to(ROOT)),
                                   'sha256': hashlib.sha256(captured[source]).hexdigest()}
                                  for source in [*sources, diagnostic_types, diagnostics]]}))


if __name__ == '__main__':
    main()
