# Physics Bone System v2.4.0 — Unified Physics candidate

This update makes movement resistance stay responsive at Minecraft speeds. The solver now integrates quadratic drag implicitly instead of clipping drag acceleration at a fixed value.

Reusable secondary-bone simulation for Figura avatars. The V2 source is isolated from Physics Studio v1; it neither loads nor changes the V1 files.

## What it does

- Simulates a selected chain of transformable `GROUP` ModelParts with a fixed-step Verlet solver.
- Supports free, cone, and hinge joints, local or world gravity, gravity falloff, spring/pull, damping, mass, bending stiffness, avatar-motion drag, linear motion response, and parent-frame rotational inertia.
- Lets each component use its own settings and per-link overrides. Branched hierarchies require an explicit branch choice.
- Uses one avatar-wide PhysicsWorld and scheduler for component chains, global and component-attached colliders, graph-aware self-collision, cross-component contacts, and Minecraft block collision shapes.
- Provides the F8 editor, a collapsible model Outliner, per-parameter text entry/sliders, collider setup, diagnostics, and Shift+` bone gizmos.
- Includes editable starter profiles for hair, ears, tails, hanging accessories, and bone-based clothing. Saves local settings per avatar through Figura Config; `physics_bone_preset.lua` can provide a portable whole-avatar profile.

The solver moves ModelParts by adding rotations over the current animation. It does not deform a mesh, move the Minecraft player, or create a native rigid-body/ragdoll simulation. PhysBone does not fetch or install Figura for users.

F8 opens in **Основные настройки**: world/local gravity direction, gravity strength in multiples of Earth gravity, animation follow, motion response, settling, and bend freedom. Select **Подробнее** for the full technical controls, including per-axis gravity, mass, spring, damping, and joint type. A new or reset component starts at 1× gravity, 30% animation follow, 25% movement response, 50% settling, and 11% bend freedom. Existing avatar-local saved profiles remain unchanged until reset or edited. Resetting a component also removes its per-link overrides; export the profile first if you need to keep them.

Gravity remains active while an animation plays. The current animation provides the pose target; gravity pulls simulated links down, and animation follow pulls them back toward that pose. If the gravity response looks too weak, lower animation follow first. In the basic page, the gravity slider and direction choice use a straight downward vector in the chosen frame; custom X/Y/Z gravity vectors are available under **Подробнее**.

`Возврат к анимации` pulls each link toward its current animated pose. Strong pull can keep a curled tail in that shape even while the avatar moves; weaker pull allows more inertial trailing and takes longer to restore the pose. `Сопротивление среды` applies quadratic resistance to each link's velocity through the stationary game world, including avatar translation and rotation. It adds no external wind or constant push. Resistance is stronger across a long link than along it, so the chain tends to trail behind its moving base. `Жёсткость изгиба` pulls neighboring-link angles toward the animated bend, so it may preserve a curl; it does not straighten the chain by itself. These settings are independent and configurable per link.

## Install into an avatar

1. Copy every `physics_bone_*.lua` file in this directory into the avatar folder. Do not copy the `tests/` directory into a release avatar.
2. Add `physics_bone_loader` to that avatar's `autoScripts` in `avatar.json`. Preserve its other scripts, for example:

   ```json
   "autoScripts": ["script", "physics_bone_loader"]
   ```

3. Load the avatar in Figura and press **F8**. Select the chain's first transformable group, create a component, resolve any branch prompts, and inspect its links before enabling it.
4. Each simulated link needs its own transformable `GROUP` pivot. The next child pivot defines the segment endpoint; use a manual endpoint for the final link when it has no child group.
5. Use **Shift+`** to toggle the temporary bone/physics gizmos. Remove the test-only `physics_bone_test_driver` from `autoScripts` before distributing the avatar.

See [INSTALLATION.md](INSTALLATION.md) for a fuller setup and recovery guide.
For a short Russian setup path, see [QUICK_START_RU.md](QUICK_START_RU.md).

## Presets and saved settings

The editor's **Save** action stores an avatar-local profile in Figura Config. Those values take precedence over a bundled preset. To share settings with an avatar:

1. Select **Export profile v2** in the editor. Figura writes JSON and Lua copies under `figura/data/PhysicsBoneV2/Characters/…`.
2. Copy the generated `physics_bone_preset.lua` beside the avatar's other Lua files. The JSON file is a separate backup; the runtime loads the Lua module.
3. A user with no local V2 profile gets the bundled preset automatically. Someone who already has local settings can click **Load physics_bone_preset.lua** and then **Save** to adopt it.

The example in `examples/deepsi_tail.physics_bone_preset.lua` only matches the Deepsi test rig's hierarchy. For another model, create its component in F8 and export its own profile.

## Collision controls

Collisions are off by default. Enable them per component, then choose avatar colliders, block shapes, or self-collision. Sphere/capsule colliders are attached to model groups; configure their path, radius, capsule length/axis, and pivot offset in the editor. The per-link collision radius represents a simulated point's thickness.

World queries use Figura's block collision boxes under one shared per-tick budget. Reusable avatar-wide colliders and component-attached colliders can contact all compatible components through collision groups and masks. Dynamic contact uses a spatial broadphase, bounded candidate-pair budget, point-segment contact, and an optional segment-segment tier; self-collision filters adjacent links using graph distance. Contact iterations, friction, and restitution are configurable. Components whose transform frame is unavailable are skipped for that contact step and counted in diagnostics; unavailable block-shape queries fail open so animation continues.

## Limits and compatibility

- A single mesh without separate transformable groups cannot become a simulated bone chain.
- Self-collision is graph-distance filtered within a component. Different components can contact each other when both components enable physical contacts, their masks/groups permit the pair, and a shared global budget remains.
- Avatar colliders are spheres or capsules anchored to ModelParts. There are no entity, item, or arbitrary mesh colliders.
- Block contact uses Minecraft block collision shapes; it is bounded by the configured query budget and is not a replacement for the player's hitbox. Fast motion can still tunnel past thin surfaces when the query or solver budget is exhausted.
- The system depends on Figura's ModelPart transform path. Mods that directly replace the rendered model or bypass these transforms are not guaranteed to compose correctly.
- Figura runs avatar scripts client-side. This library does not guarantee synchronized bone positions between viewers.

See [KNOWN_LIMITS.md](KNOWN_LIMITS.md) for behavior that is covered by live tests and remaining boundaries.
See [ACCEPTANCE_REPORT.md](ACCEPTANCE_REPORT.md) for the latest live test metrics and tested scope.

## Test the build

`Animation_PhysBone_V2_3_9_Regression_Test/` and `Animation_PhysBone_V2_MultiChain_Test/` are historical v2.3.9 live fixtures. Their copied reports describe that older build, not the current unified-physics source. `Animation_PhysBone_V2_Manual_Tuning_Test/` is a separate manual fixture. The fixtures are separate from the production avatar. Remove the test-only `physics_bone_test_driver` from `autoScripts` before distributing an avatar.

The archived multi-chain world-collision phase seeds only the tail against a nearby Minecraft block. It leaves the ears in their normal pose so the collision test does not teleport unrelated short chains into the same block.

Reports are written below the active Minecraft instance's `figura/data/PhysicsBoneV2/` folder:

- One-chain Deepsi integration: `AnimationIntegrationDiagnostics/physbone_v2_animation_integration.json`.
- Three-chain run: `AnimationIntegrationDiagnostics/physbone_v2_multichain_live.json`.
- Each report's sibling `_status.json` shows whether its driver is running, complete, or failed. Verified report snapshots are copied into this package as `latest-live-animation-integration-test.json` and `latest-live-multichain-test.json`.

Run the validator from the workspace using the report for the test avatar you loaded:

```powershell
node "Physics_Bone_System_V2\tests\report_version_guard.test.cjs"

$data = "$env:APPDATA\.minecraft\versions\<instance>\figura\data\PhysicsBoneV2"
$env:PHYSBONE_EXPECTED_VERSION = '2.3.9'
$env:PHYSBONE_EXPECTED_CHAIN_COUNT = '1'
node "Physics_Bone_System_V2\tests\live_rotation_report.test.cjs" "$data\AnimationIntegrationDiagnostics\physbone_v2_animation_integration.json"

$env:PHYSBONE_EXPECTED_CHAIN_COUNT = '3'
node "Physics_Bone_System_V2\tests\live_rotation_report.test.cjs" "$data\AnimationIntegrationDiagnostics\physbone_v2_multichain_live.json"
```

The validator requires an exact `PHYSBONE_EXPECTED_VERSION` on every run, so a stale report from another release cannot pass silently. The listed reports are v2.3.9 snapshots; use them as baseline evidence only, not as a live acceptance run of the unified-physics implementation.

The report records the test cases and thresholds; it does not claim that every third-party animation, arbitrary world, or avatar is covered.

## Rollback

Remove `physics_bone_loader` from `autoScripts` to disable V2. The original V1 scripts and the production avatar remain separate.
