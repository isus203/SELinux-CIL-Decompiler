# DumprX SEPolicy

Decompiles the SELinux policy of an Android firmware dump (dumpyara / DumprX) back into
readable `.te` rules and contexts files, using `decompile_cil.py` from
[LineageOS/scripts](https://github.com/LineageOS/scripts/tree/main/dev) (synced with upstream).

The same `decompile.sh` entry point is used in a terminal and in GitHub Actions. It:

- reads only what is needed from the dump (`system`, `system_ext`, `product`, `vendor`
  `etc/selinux`, `build.prop`, `build_flags.json`, recovery `sepolicy`), and for a git URL
  does a sparse, blobless clone of just those files, so a 10+ GB dump is not downloaded;
- understands the dumpyara layout (`system/system/...`) and flat dumps;
- fetches AOSP/LineageOS `system/sepolicy` (macros and `prebuilts/api/<version>`);
- uses `checkpolicy`/`secilc` from `$CHECKPOLICY`/`$SECILC`, an Android `out/host/linux-x86/bin`
  or `$PATH`, otherwise builds them from SELinuxProject sources.

## GitHub Actions

1. Open the **Actions** tab, select **DumprX SEPolicy**, click **Run workflow**.
2. Paste the git URL of the dump repository (optionally its branch and the
   `android_system_sepolicy` branch, default `lineage-23.2`).
3. Download the `decompiled_sepolicy` artifact when the run finishes.

The built tools and `system/sepolicy` are cached between runs.

## Terminal

Requirements: Python >= 3.11, git, and to build the tools if they aren't installed:
`make`, a C compiler, `flex`, `bison`.

```sh
# local dump folder
./decompile.sh -d ~/dumps/tecno_lj9 -o out

# dump repository (only the SELinux files are downloaded)
./decompile.sh -d https://gitlab.com/user/android_dump_device.git --dump-branch main -o out

# inside an Android tree (uses its system/sepolicy and out/host tools)
SEPOLICY_ANDROID_ROOT=~/android/lineage ./decompile.sh -d ~/dumps/device -o out
```

Mixed firmwares (a vendor older than system, e.g. an Android 14 vendor with an Android 16
system, common on MediaTek) are supported: each part is decompiled with the sources of its own
Android release. In that case the recovery policy is skipped by default (`not_recovery()` /
`recovery_only()` aren't generated), because its reference policy would mix two releases;
`--recovery` forces it.

ODM: `odm/etc/selinux/precompiled_sepolicy` is only the whole device policy compiled ahead of
time (on the TECNO LJ9 dump it's identical to the policy built from the system, system_ext,
product and vendor `.cil` files), so there is nothing extra to decompile. A real
`odm_sepolicy.cil` isn't supported by `decompile_cil.py`: the script warns when it finds one.

`./decompile.sh --help` lists all options. Anything after `--` is passed to `decompile_cil.py`
(for example `-- --extra-macros path/to/macros --cleanup-rules path/to/rules`).

## Changes compared to upstream

- `utils/utils.py`: `android_root` can be set with `SEPOLICY_ANDROID_ROOT`/`ANDROID_BUILD_TOP`
  and is auto-detected as the first parent folder containing `system/sepolicy`.
- `sepolicy/compile_utils.py`: `checkpolicy`/`secilc` are also looked up in `$CHECKPOLICY`,
  `$SECILC` and `$PATH`.
- `sepolicy/cil_policy.py`: vendors built before Android 15 are supported: a missing
  `etc/build_flags.json` is treated as "all flags false", and without `ro.board.api_level`
  the vendor policy version comes from `vendor/etc/selinux/plat_sepolicy_vers.txt`
  (then `ro.vndk.version` / `ro.vendor.build.version.sdk`).
- `sepolicy/source_te_policy_provider.py`: the unversioned `system/sepolicy/vendor` rules are
  read from `prebuilts/api/<version>/vendor` when it exists. `decompile.sh` fills it with the
  `vendor` folder of the matching LineageOS release when the device vendor is older than
  `system/sepolicy` (for example an Android 14 vendor with an Android 16 system), then
  `tools/filter_vendor_sepolicy.py` drops the HALs whose types aren't in the device policy
  (the release branch can be newer than the snapshot the OEM built the vendor from).
- `sepolicy/source_te_policy_provider.py`, `sepolicy/source_text.py`: when the prebuilt API
  version has no `nlmsg_defines`/`nlmsg_macros` (Android 14 and older), they are taken from the
  current `system/sepolicy/public`, because the unversioned `system/sepolicy/vendor` rules use them.
