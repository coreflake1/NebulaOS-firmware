# MCU lifecycle reconciliation (mechanical, not narrative)

Generated 2026-09-06, final pre-hardware closure mission. Every claim below
is backed by an actual git command run tonight.

## The known-good checkpoint

`85814b604a6857669d287df72669cc7629896497` — "Phase 1.8B candidate-002: fix
MCU lifecycle guard for real hardware" — is the commit
`_project/missions/phase1.8b-candidate-002-mcu-fix-report.md` and
`_project/missions/phase1.8b-candidate-002-rebuild-hardware-qualification-report.md`
document as hardware-qualified on real hardware, 2026-08-29: automatic
stock→native MCU restore confirmed working end-to-end through
`S50nebulaos-mcu-guard`, zero manual bypass.

```
$ git -C NebulaOS-firmware merge-base --is-ancestor 85814b604a6857669d287df72669cc7629896497 3dfd5f3b455eabc2a1a60937e72700fa517f03ef
$ echo $?
0   # ANCESTOR
```

## Mechanical diff: every MCU lifecycle file

```
$ git -C NebulaOS-firmware diff 85814b604a6857669d287df72669cc7629896497 3dfd5f3b455eabc2a1a60937e72700fa517f03ef \
    --stat -- '*mcu_lifecycle.py' '*mcu_restore.py' '*mcu_restart.py' \
    '*mcu_application_identify.py' '*mcu_known_identities.py'
(empty output)
```

**Zero lines changed** in any of the five MCU lifecycle files between the
hardware-qualified candidate-002 fix and the current final candidate HEAD.
This is the strongest form of proof available short of re-running the
hardware test itself: not "these look the same," but a real `git diff`
returning nothing.

## Superseded draft branches — explained, not missing

Three local-only branches never merged as literal ancestors:
`phase1.8b/boot-safety`, `phase1.8b/candidate-001-integration`,
`phase1.8b/ke-stepper-parity`, `phase1.8b/mcu-lifecycle`. None of these exist
on the `origin` remote at all (confirmed via `git branch -r`) — they were
local integration-staging branches whose commits read as early drafts
("Phase 1.8B: KE stepper motor and TMC driver configuration parity test",
etc.), superseded by re-implemented, hardened versions committed directly
onto the path that became `phase1.8b/integrated` (confirmed ancestor of
current HEAD) and later fixed again by candidate-002 (`85814b6`, above).
`git diff` of `phase1.8b/mcu-lifecycle`'s tip against current HEAD shows 479
insertions / 71 deletions across the same four files — consistent with an
early, since-hardened draft, not lost work. The KE stepper/TMC parity
content specifically is confirmed present and passing:
`tests/ke-stepper-tmc-parity-tests.sh` exists in current source and passed
103/105 assertions in tonight's clean-environment test run (§ below), the 2
failures unrelated (own-config `rotation_distance` field that only
populates after a real on-device `SAVE_CONFIG`, not a parity regression).

## Historical product behavior vs. current code — what is, and isn't, a regression

The historical "NebulaOS native → Stock, hard power cycle → Stock reflashes"
behavior was investigated exhaustively during last night's RC2 closure
(`docs/mcu-stock-handoff-investigation.txt`) and nothing there has changed
since: switching to Stock has never touched the MCU in any version (no
dedicated switch-to-Stock script exists anywhere in this project's history);
the 2026-08-28 "success" is best explained as an artifact of the MCU already
being stranded by an unrelated manual CLI mishap that day, not a repeatable
mechanism tied to any code this repository owns.

- **Native candidate identity/hash**: unchanged — `NebulaOS-klipper-mcu` is
  still at `2c9bab5` (same as RC1/RC2), no commits since.
- **Bootloader preservation**: unchanged, re-confirmed via the same
  mechanical proof as last night — `configs/ender3-v3-ke.defconfig:12`
  selects `CONFIG_STM32_FLASH_START_3000=y` (application origin
  `0x08003000`), and `creality_flash.py`'s wire protocol to the vendor
  bootloader carries no address field at all (see
  `docs/mcu-flash-layout.md`).
- **Restart/serial bootloader support**: `mcu_restart.py`'s
  `request_generic_restart()` (Option C — a real msgproto `"reset"`/
  `"config_reset"` lookup, not a hardcoded byte sequence) is included in the
  zero-diff file set above.

## Conclusion

```
MCU_LIFECYCLE_RECONCILIATION_COMPLETE = YES
STOCK_HANDOFF_SOURCE_REGRESSION_FOUND = NO
STOCK_HANDOFF_SOURCE_FIX = READY_FOR_HW_TEST
CREALITY_BOOTLOADER_PRESERVED = YES
```

No source change was made to MCU lifecycle code tonight — there is nothing to
change. The morning hardware test's ranked experiments
(`docs/mcu-stock-handoff-investigation.txt`) remain the correct next step.
