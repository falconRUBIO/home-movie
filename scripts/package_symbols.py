#!/usr/bin/env python3
"""Package native archive dSYMs before uploading the IPA."""
from pathlib import Path
import subprocess

root = Path('build')
folders = [path for path in root.rglob('dSYMs') if any(path.glob('*.dSYM'))]
if not folders:
    raise SystemExit('No archive dSYMs found; stop before uploading an unsymbolicated release.')
for index, folder in enumerate(folders):
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(folder), str(root / ('debug-symbols-' + str(index) + '.zip'))], check=True)
