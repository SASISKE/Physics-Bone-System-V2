NeedsOfNature Figura profile

Edit destroyed_skin.png and the black mask templates for each atlas.
Opaque mask pixels apply the corresponding effect; transparent pixels do not.
The split-limb group names are right_forearm, left_forearm, right_lower_leg, and left_lower_leg.
Creators can default a humanoid avatar to NoN's animation pose by adding this to profile.json:
  "animation_pose": { "mode": "humanoid_override" }
Standard humanoid parent types or exact head/body/limb names are detected automatically.
Optional animation_pose.parts paths can identify non-standard humanoid groups.
For a split torso, map waist to the pelvis group and body to its upper-torso child.
Part paths accept slash notation or copied Figura paths beginning with models.
To replace the default D geometry, create independent d1 (shaft) and b (balls) groups under the torso.
An optional d group may organize both. Neither target may contain the other; only the shaft subtree is culled.
The rig keys d1 and b can map custom group names. The old rig.d key is ignored; old replacements need migration.
The default D geometry is hidden automatically when both groups are present.
