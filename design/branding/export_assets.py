#!/usr/bin/env python3
"""Export the approved Budgie artwork into the native app's asset slots.

Uses macOS sips for PNG size exports. Run from the repository root.
"""

import json
from pathlib import Path
import re
import subprocess


BRANDING = Path(__file__).resolve().parent
ROOT = BRANDING.parent.parent
ICON = BRANDING / 'budgie-icon.png'
MARK = BRANDING / 'budgie-mark.png'


def export(source, destination, width, height=None):
    subprocess.run(
        ['sips', '-z', str(height or width), str(width), str(source),
         '--out', str(destination)],
        check=True, stdout=subprocess.DEVNULL,
    )


def dimensions(path):
    output = subprocess.check_output(
        ['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(path)], text=True,
    )
    return tuple(int(re.search(rf'{key}: (\d+)', output)[1])
                 for key in ['pixelWidth', 'pixelHeight'])


def export_catalog(catalog, source):
    contents = json.loads((catalog / 'Contents.json').read_text())
    for image in contents['images']:
        destination = catalog / image['filename']
        if 'size' in image:
            scale = float(image['scale'].removesuffix('x'))
            width, height = (round(float(value) * scale)
                             for value in image['size'].split('x'))
        else:
            width, height = dimensions(destination)
        export(source, destination, width, height)


def main():
    assets = ROOT / 'native/Budgie/Resources/Assets.xcassets'
    export_catalog(assets / 'AppIcon.appiconset', ICON)
    export_catalog(assets / 'logo.imageset', MARK)
    export_catalog(ROOT / 'native/BudgetWidgets/Assets.xcassets/BudgieLogo.imageset', MARK)
    print('Exported Budgie icon, logo and widget logo.')


if __name__ == '__main__':
    main()
