# PhysBone System V2 — Unified Physics implementation plan

**Target branch:** `feature/unified-physics`  
**Approved design:** `../specs/2026-11-01-physbone-unified-physics.md`  
**Scope:** implementation inside this avatar repository; no remote push/publication.

## Guardrails

- Keep `physics_core.lua`, `physics_studio.lua`, `physics_ui.lua`, `script.lua`, `model.bbmodel`, avatar manifest, and installed V1 behavior unchanged unless an explicit integration point requires a small, isolated edit.
- Keep all new runtime modules under the `physics_bone_` namespace; do not copy the D: package wholesale. The V2 Lua source files currently match the D: package; this repository also has its own Lua self-tests and `physics_bone_preset.lua`.
- Add regression tests before behavior changes. Preserve the existing local Verlet/fixed-step solver and its compatibility/config migration paths.
- Never run a full simulation from `RENDER`; only consume interpolated state there.
- No remote Git operations. Commit only if useful for safe milestones; do not push.

## Baseline

- Local Git branch `feature/unified-physics`, clean at `2389c7e12648b3972d324c65abbacf791f001464` before this plan.
- Existing V2 modules: chain, config, constraints, core, collisions, registry, studio, UI, gizmos, input, loader, preset.
- Existing self-tests: chain, collision, solver. Current standalone environment has no `lua`, `luajit`, or `luac`; use the available repository test runner and Figura self-tests where possible, and clearly distinguish stored reports from fresh runs.

## Work sequence

### 1. Lock solver contracts and regressions

1. Audit actual C: module interfaces and existing self-tests; record current build/version and fixed-step timing behavior.
2. Add failing regressions for branched self-collision exclusions, deterministic pair de-duplication, zero/unequal inverse-mass correction, and validation of malformed values.
3. Replace index-distance self-collision filtering with graph-distance filtering over real edges and configurable neighbor depth.
4. Make spring/mass/pull semantics explicit and mathematically meaningful; retain compatible stored fields through migration or documented aliases.
5. Run every existing Lua/self-test path available; keep new cases in the V2 test modules.

**Gate:** chain, solver, collision tests pass; no V1 source changes.

### 2. Add the shared PhysicsWorld

1. Introduce `physics_bone_world.lua` as the coordinator for independently configured components.
2. Define a stable component contract: topology/settings/state, points/current-previous positions, links/segment radii, inverse masses, collision filter/group, and coordinate frame.
3. Move frame scheduling to one world tick: sample all animation targets and frames, integrate all components at a shared fixed timestep, solve local constraints, publish points, then run shared collision work.
4. Keep `studio` as the Figura-facing adapter and preserve its editor lifecycle; remove per-component duplicate world scheduling without changing the avatar animation controller.
5. Add world registry/lifecycle tests for add/remove/rebuild, stable ordering, and no stale component references.

**Gate:** multiple components advance exactly once per fixed substep and existing single-component behavior remains compatible.

### 3. Implement global dynamic collisions

1. Add a bounded spatial hash/broadphase over points and segments from every enabled component.
2. Add category/group masks (Body, Hair, Ears, Tail, Clothing, Accessories) and preserve explicit include/exclude controls.
3. Resolve point-point and point-segment contacts across components with inverse-mass weighting; add segment-segment where the selected quality tier permits.
4. Use swept bounds/CCD for candidate moving pairs; process each pair once and cap pair/contact work deterministically.
5. Re-run limited local length/angle constraints after contacts, then validate finite state and link lengths; do not finish with a collision projection that breaks constraints.
6. Reuse world/body colliders and preserve block collision support.

**Gate:** independent chains push one another in both directions, graph neighbors are excluded correctly, and length error stays inside the documented tolerance.

### 4. Add animation-space integration modes

1. Add Animation Driven, Hybrid, and Rest Pose target modes with `animationInfluence` separate from `pull` and `bendStiffness`.
2. Keep animation targets as external inputs; never feed output offsets back into the next target sample.
3. Support calibration capture/save/recapture/reset/restart with explicit validation so arbitrary animated poses are not silently captured as rest pose.
4. Keep motion/gravity in the configured coordinate frame and test head/body tilt plus animation transitions.

**Gate:** tests show animation following and secondary motion remain separately adjustable; no target drift over repeated frames.

### 5. Performance tiers and instrumentation

1. Add Performance/Balanced/Quality modes with documented fixed-step, substep, contact-pass, pair-budget, and world-query limits.
2. Enforce global deterministic budgets with graceful degradation; avoid all-pairs scans, hot-loop `pcall`, and avoidable per-tick table allocation.
3. Cache hierarchy/collider data and reuse scratch buffers; keep render interpolation read-only.
4. Gather timings/counters only when diagnostics are open or enabled.

**Gate:** counters prove global budgets are respected under 1/3/5-chain and 32–96 point loads; no per-frame full simulation during render.

### 6. Configuration and F8 Physics Studio

1. Migrate schema safely; preserve local Figura Config precedence, portable bundled preset loading, and existing component/link overrides.
2. Add component types/presets (Hair, Ears, Tail, Clothing, Accessories) without hard-wiring Deepsi paths.
3. Add F8 pages: Overview, Components, Colliders, Collision Groups, Physics Settings, Performance, Diagnostics. Preserve existing table-aligned visual style and correct hitboxes.
4. Add sphere/capsule collider editing and reusable body collider attachment; visualize colliders and collision groups with gizmos.
5. Show active components/nodes/proxies, candidate/resolved pairs, budgets, block queries, timings, and actionable warnings. Keep diagnostic-only work out of the normal hot path.

**Gate:** every setting can be reached/edited with matching hitboxes, saved and reloaded; old profiles migrate without overwrite.

### 7. End-to-end verification and handoff

1. Expand regression coverage to single/multiple/branched chains, 32–96 points, animation transitions, body tilt/gravity, cross-component and body/world collision, and budget overflow.
2. Prepare a separate minimal Figura test fixture/driver without editing the production model or `script.lua`.
3. Run all available static/unit/integration checks. If Minecraft is not controllable in this session, do not label live-game behavior verified; provide a concise exact in-game checklist and report the remaining validation separately.
4. Update README and migration/parameter documentation with actual solver math, units, coordinate frames, limitations, and profile sharing behavior.
5. Review diffs for accidental V1/model/manifest changes and verify cleanly scoped Git changes on the feature branch.

## Acceptance criteria

- A reusable `PhysicsWorld` owns scheduling and contacts across multiple components.
- Branched graph self-collision uses topology depth, not array index distance.
- Cross-component collision is mutual, filtered, bounded, and stable after final constraints.
- Animation target influence, pull, bend stiffness, spring, mass, damping, and gravity have explicit independent meanings and migrations.
- Presets work on arbitrary compatible Figura avatars without Deepsi-only assumptions.
- F8 exposes the specified pages and meaningful diagnostics while respecting performance budgets.
- Existing tests pass; new tests cover the new contracts; live Figura results are clearly reported as tested or still pending.
- V1, model, animation controller, and avatar manifest remain unchanged unless explicitly listed and justified in the final report.
