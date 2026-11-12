#!/usr/bin/env python3
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
"""
Keep only the parts of a system/sepolicy/vendor folder that exist in a device policy.

system/sepolicy/vendor of a release can contain HALs that the device vendor (built
from an older snapshot of that release) doesn't have, e.g. hal_authgraph_default in
lineage-21.0 vs an early Android 14 MediaTek vendor. Their rules reference attributes
missing from the frozen prebuilts/api/<version> policy and break checkpolicy.

Usage: filter_vendor_sepolicy.py <vendor sepolicy dir> <device .cil file>...
"""

import re
import sys
from pathlib import Path

CIL_TYPE_RE = re.compile(r'^\(type ([^\s)]+)\)', re.MULTILINE)
TE_TYPE_RE = re.compile(r'^\s*type\s+([A-Za-z0-9_]+)\s*[,;]', re.MULTILINE)
CONTEXT_TYPE_RE = re.compile(r'u:(?:object_r|r):([A-Za-z0-9_]+):s0')

CONTEXTS_FILES = (
    'file_contexts',
    'vndservice_contexts',
    'hwservice_contexts',
    'service_contexts',
    'property_contexts',
    'seapp_contexts',
)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 1

    vendor_dir = Path(sys.argv[1])
    declared = set()
    for cil_path in sys.argv[2:]:
        path = Path(cil_path)
        if path.is_file():
            declared.update(CIL_TYPE_RE.findall(path.read_text(errors='replace')))

    if not declared:
        print('No types found in the device policy, not filtering', file=sys.stderr)
        return 0

    removed_files = []
    for te_path in sorted(vendor_dir.glob('*.te')):
        types = TE_TYPE_RE.findall(te_path.read_text(errors='replace'))
        # The first declared type is the domain the file is about
        if types and types[0] not in declared:
            te_path.unlink()
            removed_files.append(te_path.name)

    removed_lines = 0
    for name in CONTEXTS_FILES:
        contexts_path = Path(vendor_dir, name)
        if not contexts_path.is_file():
            continue

        kept = []
        for line in contexts_path.read_text(errors='replace').splitlines():
            context_types = CONTEXT_TYPE_RE.findall(line)
            if context_types and any(t not in declared for t in context_types):
                removed_lines += 1
                continue
            kept.append(line)
        contexts_path.write_text('\n'.join(kept) + '\n')

    print(
        f'Vendor sepolicy filter: removed {len(removed_files)} .te files '
        f'and {removed_lines} contexts lines not present on the device'
    )
    for name in removed_files:
        print(f'  - {name}')

    return 0


if __name__ == '__main__':
    sys.exit(main())
