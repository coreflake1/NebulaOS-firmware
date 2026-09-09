# NebulaOS-klipper-extensions branch strategy

Phase 2 final software closure mission, 2026-09-09.

## The problem

Moonraker's `[update_manager nebulaos_klipper_extensions]` section had
`primary_branch: main`. A real device found live had `is_valid: false` and
`anomalies: ["Repo has diverged from remote"]`.

Mechanical root cause (verified via `git merge-base`, not guessed):

```
merge-base(deployed_pin, origin/main) == origin/main
git merge-base --is-ancestor origin/main deployed_pin   -> true
git merge-base --is-ancestor deployed_pin origin/main   -> false
```

`origin/main`'s tip is a strict ancestor of the deployed pin - the deployed
pin is 31 commits *ahead* of `main`, not diverged from it in the git-history
sense. This is a direct, expected consequence of this project's own standing
rule, repeated in every phase mission: **do not merge in-development phase
work to `main`**. Every qualified pin advances on a phase branch
(`phase2/calibration-framework`, etc.), never on `main` itself - so `main`
necessarily stays behind whatever commit is actually built and pinned.

Moonraker's `git_repo` update_manager, when the local checkout is ahead of
the configured `primary_branch`'s remote tip rather than behind-or-equal to
it, reports this as divergence (`is_valid: false`) rather than "no update
needed."

## The fix

A dedicated branch, `production`, that this project fast-forwards to match
`KLIPPER_EXTENSIONS_PIN` (`manifests/dependencies.conf`) on every qualified
release:

- `main` stays untouched - reserved for an eventual public/1.0 promotion,
  exactly as every other mission on this repo has already established.
- `production` always has the currently-pinned, currently-deployed commit
  as its tip, so Moonraker's update_manager always has a real remote branch
  to compare the local checkout against, and reports `is_valid: true`.
- `phase2/calibration-framework` (and future phase branches) remain the
  actual working branches where development happens; `production` is
  fast-forwarded from whichever phase branch is currently qualified,
  never developed on directly.

## What changed

- `manifests/dependencies.conf`: `KLIPPER_EXTENSIONS_BRANCH=main` ->
  `KLIPPER_EXTENSIONS_BRANCH=production`.
- `scripts/build/overlay/etc/nebulaos/moonraker/klipper-pin.conf`:
  `primary_branch: main` -> `primary_branch: production`.
- `scripts/build/00-fetch-vendor-sources.sh`'s `clone_pinned()`: gained a
  `local_branch` parameter, used for the extensions call site. A real,
  independently-verified bug was found and fixed here at the same time:
  the previous non-shallow clone path did a bare `git checkout "$ref"`
  after cloning, which unconditionally produces a **detached HEAD** even
  when `$ref` equals the current branch tip - verified empirically. On a
  genuinely fresh clone (`vendor/` is gitignored, so every fresh-clone
  build hits this), the seed archive would have shipped a detached-HEAD
  `.git`, which `06-verify.sh`'s `check_seed_archive()`
  (`symbolic-ref --short HEAD`) would have failed. This was previously
  masked only because a long-lived, never-freshly-cloned local `vendor/`
  checkout happened to already be attached to the right branch from an
  earlier, differently-behaved checkout. `clone_pinned()` now does
  `checkout -B "$local_branch" "$ref"` and wires
  `branch.<name>.remote`/`.merge`, the same mechanism the shallow (Klipper)
  path already used correctly.
- `scripts/build/04-cross-compile-app-stack.sh`: the seed-manifest.json's
  hardcoded `"branch": "main"` literal for the extensions entry now reads
  `$KLIPPER_EXTENSIONS_BRANCH` instead, so the recorded metadata can never
  drift from the branch actually used.

## Maintaining this going forward

Whenever `KLIPPER_EXTENSIONS_PIN` advances to a new qualified commit:

```
git -C NebulaOS-klipper-extensions push origin <new-pin-sha>:production
```

(a plain fast-forward push of the pin commit onto `production`). Never
force-push `production` unless deliberately rolling back a pin - a normal
pin advance is always a fast-forward from the previous pin's own history.
