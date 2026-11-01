# Unified PhysBone implementation ledger

## Start state

- Branch: `feature/unified-physics`
- Baseline: `2389c7e12648b3972d324c65abbacf791f001464`
- Before docs were added, source tree was clean.
- `physics_bone_*.lua` implementation files matched the D: working package; this C: repository has additional root-level self-tests and its own preset.
- No recursive `AGENTS.md` was found in the target repository.
- Current shell has Node.js but no `lua`, `luajit`, or `luac` command. Stored live JSON reports are baseline evidence only, not verification of new code.

## Rulings

- Ruling: implement directly on `feature/unified-physics` in the user-designated C: repository rather than creating a second worktree — this folder is the requested local Git repository and is already isolated on a clean feature branch; the cost if wrong is reduced isolation, mitigated by the branch and the verified pre-change backup.
- Ruling: preserve `physics_*.lua`, `script.lua`, `model.bbmodel`, avatar manifest, and V1; integrate only the `physics_bone_*.lua` path plus documentation/test fixture — the TЗ calls for reusable V2 and existing V1 compatibility; the cost if wrong is a narrow integration gap, which will be made explicit in final verification.
- Ruling: do not treat stored reports as live tests — reports predate this branch's implementation and therefore cannot validate it.

## Task status

- [x] Copy approved TЗ into repository docs.
- [x] Write implementation plan.
- [ ] Phase 1: solver contracts and regressions.
- [ ] Phase 2: shared PhysicsWorld and scheduler.
- [ ] Phase 3: global dynamic collision and filters.
- [ ] Phase 4: animation target modes and calibration.
- [ ] Phase 5: performance modes and instrumentation.
- [ ] Phase 6: config migration, presets, and F8 Studio pages.
- [ ] Phase 7: regression/live verification and docs.

## Work notes

- Delegate `/root/branched_self_collision` owns only `physics_bone_collisions.lua` and `physics_bone_collision_selftest.lua`; no other files are in scope.
