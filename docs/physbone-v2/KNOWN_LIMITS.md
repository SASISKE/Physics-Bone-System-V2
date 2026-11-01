# Coverage and known limits

## Current implementation

V2 uses a shared fixed-step PhysicsWorld to advance enabled components on the same tick schedule. The world builds a bounded spatial broadphase, resolves compatible dynamic contacts between chains, applies component and avatar-wide sphere/capsule colliders, and shares its block-query and candidate-pair budgets. Self-collision excludes neighbors by graph distance. Components with unavailable transform frames are skipped for that contact pass and reported in diagnostics rather than crashing the script.

The installed source tree is checked with LuaJ self-tests for chain construction, config migration, constraint solving, graph-aware self-collision, unified scheduling, world contacts, UI interaction, and runtime imports. These tests validate code contracts in Figura's LuaJ runtime; they do not replace an in-game acceptance run on every avatar.

The checked-in `latest-live-*.json` reports were produced by v2.3.9 fixtures before the unified PhysicsWorld changes. They are historical baseline data and must not be described as validation of the current source. A new live report is valid only when its avatar/test-driver version and chain count match the source under test.

## Simulation boundaries

- This is a client-side articulated point-chain simulation, not Unity PhysBones, a general rigid-body engine, or a ragdoll.
- A component rotates transformable `GROUP` ModelParts around their existing pivots. It cannot deform vertices in a single mesh, move the Minecraft player, or change the player's hitbox.
- One component follows its configured chain graph. At a fork, the user must choose a branch or explicitly include all branches; any one point still has a single transform in the model hierarchy.
- Collision shapes are spheres and capsules attached to avatar groups or declared as avatar-wide reusable colliders. There are no entity, held-item, or arbitrary-mesh colliders.
- Cross-component contacts are approximate point-segment or optional segment-segment contacts. The selected collision groups and masks, component toggles, solver iterations, and shared candidate budget determine which contacts fit into a tick.
- Block contacts use shapes returned by Figura's world API. Unloaded/unsupported shapes fail open, and exhausted query or pair budgets can leave contacts unresolved. Thin geometry can still be crossed at high speed if the configured substep and collision budgets are insufficient.
- A missing or invalid world transform prevents that component from participating in world-frame proxy/contact processing for that tick. Diagnostics expose the skipped frame; no transform is guessed from the player's yaw.
- The system depends on Figura's ModelPart transform pipeline. A mod that replaces those transforms may not compose with the solver. Figura scripts run client-side, so other viewers are not guaranteed identical simulated bone positions.

## Live acceptance still matters

Before calling a build release-ready, load its current files in Minecraft and inspect a neutral pose, locomotion, avatar rotation/inversion, component-to-component contact, avatar colliders, block contact, F8 save/reload, and behavior when a frame is temporarily unavailable. Record a new report from the tested build; the v2.3.9 snapshots only serve as earlier baseline evidence.
