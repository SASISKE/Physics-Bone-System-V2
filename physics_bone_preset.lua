-- Test-only PhysBone profile for Deepsi's tail.001 -> tail.011 chain.
-- This is intentionally bundled with the isolated PhysBone v2 test avatar.
return {
  schema = 1,
  diagnostics = false,
  components = {
    {
      id = "physbone_deepsi_tail_test",
      name = "Deepsi manual tuning",
      enabled = true,
      rootPath = {
        { name = "root", sameNameIndex = 1 },
        { name = "Body", sameNameIndex = 1 },
        { name = "taz", sameNameIndex = 1 },
        { name = "tail.001", sameNameIndex = 1 },
      },
      branchMode = "selected",
      branchChoices = {
        ["root[1]/Body[1]/taz[1]/tail%2E001[1]/tail%2E002[1]/tail%2E003[1]/tail%2E004[1]/tail%2E005[1]/tail%2E006[1]/tail%2E007[1]/tail%2E008[1]"] =
          "root[1]/Body[1]/taz[1]/tail%2E001[1]/tail%2E002[1]/tail%2E003[1]/tail%2E004[1]/tail%2E005[1]/tail%2E006[1]/tail%2E007[1]/tail%2E008[1]/tail%2E009[1]",
      },
      excludedPaths = {},
      endpoint = {
        mode = "manual",
        vector = { x = 0, y = 1.083, z = 0.205 },
      },
      settings = {
        enabled = true,
        gravitySpace = "world",
        gravity = { x = 0, y = -9.81, z = 0 },
        gravityFalloff = 0,
        pull = 8,
        spring = 0.22,
        damping = 4,
        mass = 1,
        bendStiffness = 0.75,
        rootMotionResponse = 0.45,
        motionDrag = 0.25,
        avatarMotionResponse = 0.55,
        maxLinearSpeed = 24,
        joint = {
          type = "free",
          axis = { x = 0, y = 1, z = 0 },
          angle = 180,
          angularSpeed = 720,
        },
      },
      linkOverrides = {},
    },
  },
}

