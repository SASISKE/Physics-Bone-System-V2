# Installation and first setup

## Add the runtime

Copy the V2 Lua modules from this folder into the root of the avatar directory. In `avatar.json`, add `physics_bone_loader` to `autoScripts` without removing the avatar's animation/controller scripts:

```json
"autoScripts": ["script", "physics_bone_loader"]
```

Do not add `physics_bone_test_driver` to an avatar you intend to use normally. It is a fixture-only animation test and deliberately moves the test rig.

## Build a chain

1. Open the avatar in game and press **F8**.
2. Select the first transformable group in the chain and create a PhysBone component.
3. If the selected group has multiple transformable children, choose the branch the chain should follow. One component follows one chosen branch at a fork.
4. Check the listed link pivots. A zero/near-zero pivot interval is not a physical link; fix the group pivots in the model or exclude that group.
5. Set the final endpoint to the next child pivot or choose a manual endpoint vector. The endpoint belongs to the last simulated segment.
6. Choose a component category, then choose a starter profile and click **Apply profile**. This copies its initial values into the component; you can still edit every parameter afterward. Applying a different profile replaces that component's physics values.
7. Enable the component after the chain and rest pose look correct. Use **Shift+`** for the gizmos and **Save** to persist the profile.

The solver rotates a ModelPart group around its existing pivot. Long chains can accumulate each link's allowed angle, so test the whole silhouette after choosing joint limits. `free` permits the full range, `cone` limits deflection from the animated direction, and `hinge` limits motion around the configured local axis.

## Add avatar colliders

On the **Colliders** page, create an avatar-wide sphere or capsule and attach it to a stable transformable group. Set its collision group and mask, then adjust model-space offset, capsule axis, radius, and height. Use avatar-wide colliders for shared body shapes such as torso or hips. A collider can participate with every component whose physical contacts and collision filters allow the pair. Component-local colliders remain available when one shape should only serve one component.

Turn on **World blocks** separately to collide with Minecraft block collision shapes. Start with a modest radius and the shared query limit; raise budgets only if diagnostics report exhaustion. **Self-collision** filters non-neighbor graph points within a component and costs more as the chain grows. Different components can collide when their groups and masks permit it, under the shared PhysicsWorld pair budget.

## Share a profile

Use **Export profile v2** in F8. Find the generated Lua file under `figura/data/PhysicsBoneV2/Characters/…` and copy it to the avatar root as `physics_bone_preset.lua`. Keep the component paths intact: they identify groups by name and same-name index. First-time users load that profile automatically. Existing per-avatar Figura Config data takes precedence; the user can import the bundled file in F8 and save it to replace the local profile.

## If something does not appear

- **F8 opens nothing:** check that `physics_bone_loader` is in `autoScripts` and that all V2 modules are beside it. Read the Figura log for `[PhysBone v2]` errors.
- **The component is incomplete:** resolve every branch prompt and make sure each link is a transformable `GROUP` with distinct pivots.
- **The chain bends the wrong way:** inspect local pivot axes and the joint axis. Use a cone as the baseline before configuring a hinge.
- **World contact is absent:** confirm the component collision toggle, **World blocks**, the query limit, and that the current Figura build exposes block collision shapes. Diagnostics distinguish unavailable frame/API from an exhausted query budget.
- **A shared profile does not load:** check the exact filename `physics_bone_preset.lua`, its location beside the avatar scripts, and whether local Config already has a profile. Import it in F8 if local settings currently win.
- **Disable V2:** remove `physics_bone_loader` from `autoScripts`. This does not alter the V1 files.
