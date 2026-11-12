# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0

import os
import shutil
from contextlib import contextmanager
from pathlib import Path
from tempfile import NamedTemporaryFile

from utils.utils import (
    Color,
    android_root,
    color_print,
    run_cmd,
)


def _find_tool(name: str) -> Path:
    """
    Look for a host tool in this order:
    $CHECKPOLICY / $SECILC, <android_root>/out/host/linux-x86/bin, $PATH.
    """
    env_value = os.environ.get(name.upper())
    if env_value:
        return Path(env_value)

    android_tool = Path(android_root, 'out/host/linux-x86/bin', name)
    if android_tool.exists():
        return android_tool

    path_tool = shutil.which(name)
    if path_tool:
        return Path(path_tool)

    color_print(
        f'{name} not found: run "m {name}" in an Android tree, install it, '
        f'or set ${name.upper()}',
        color=Color.RED,
    )
    exit(-1)


checkpolicy_path = _find_tool('checkpolicy')
secilc_path = _find_tool('secilc')


@contextmanager
def _compiled_policy_path():
    temp_file = NamedTemporaryFile()
    temp_file.close()

    temp_path = Path(temp_file.name)
    try:
        yield temp_path
    finally:
        temp_path.unlink(missing_ok=True)


@contextmanager
def source_to_cil_policy(policy_path: Path):
    with _compiled_policy_path() as cil_path:
        run_cmd(
            [
                str(checkpolicy_path),
                '-C',
                '-M',
                '-L',
                '-c',
                '30',
                str(policy_path),
                '-o',
                str(cil_path),
            ]
        )

        yield cil_path


@contextmanager
def cil_to_binary_policy(policy_path: Path):
    with _compiled_policy_path() as binary_path:
        run_cmd(
            [
                str(secilc_path),
                # '-v', # no verbose
                '-m',
                '-M',
                'true',
                '-G',
                '-c',
                '30',
                # ignore neverallows
                '-N',
                str(policy_path),
                '-o',
                str(binary_path),
                '-f',
                '/dev/null',
            ]
        )

        yield binary_path


@contextmanager
def binary_to_cil_policy(policy_path: Path):
    with _compiled_policy_path() as cil_path:
        run_cmd(
            [
                str(checkpolicy_path),
                '-C',
                '-M',
                '-b',
                str(policy_path),
                '-o',
                str(cil_path),
            ]
        )

        yield cil_path
