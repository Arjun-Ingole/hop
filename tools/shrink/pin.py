#!/usr/bin/env python3
"""Writes a built shrink image's checksums, and where hop gets it, into engine/Shrink.ps1's $ShrinkImage.

    pin.py OUT_FOLDER URL      OUT_FOLDER as build.sh left it, with hop-shrink.zip and hop-shrink/

URL is the release asset for a real build, or a path on the test PC for tools/vm.
"""
import hashlib
import os
import re
import sys

out, url = sys.argv[1], sys.argv[2]
engine = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'engine', 'Shrink.ps1')


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest().upper()


files = {name: sha(os.path.join(out, 'hop-shrink', name)) for name in ('shimx64.efi', 'grubx64.efi', 'vmlinuz', 'initrd.img')}
block = ("$ShrinkImage = [pscustomobject]@{\n"
         f"    Url    = '{url}'\n"
         f"    Sha256 = '{sha(os.path.join(out, 'hop-shrink.zip'))}'\n"
         "    Files  = @{\n" + ''.join(f"        '{n}' = '{h}'\n" for n, h in files.items()) + "    }\n}")
with open(engine) as f:
    text = f.read()
new, count = re.subn(r"\$ShrinkImage = \[pscustomobject\]@\{.*?\n\}", lambda m: block, text, count=1, flags=re.S)
if count != 1:
    sys.exit('No $ShrinkImage block in engine/Shrink.ps1')
with open(engine, 'w') as f:
    f.write(new)
print(block)
