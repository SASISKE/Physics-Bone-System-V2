-- Deterministic pure-Lua checks for joints and the point-chain solver.
local solver = require("physics_bone_core")
local constraints = require("physics_bone_constraints")
local motionSampler = require("physics_bone_input")
local configApi = require("physics_bone_config")
local physicsUI = require("physics_bone_ui")

local tests = {}

local function near(a, b, tolerance)
  return math.abs(a - b) <= (tolerance or 0.001)
end

local function magnitude(value)
  return math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
end

local function finiteVector(value)
  return type(value) == "table" and value.x == value.x and value.y == value.y and value.z == value.z
    and value.x ~= math.huge and value.y ~= math.huge and value.z ~= math.huge
end

local function graphFor(points, lengths)
  local graph = { pointCount = points, links = {}, edges = {}, edgesByLink = {} }
  for index = 1, points - 1 do
    graph.links[index] = { index = index, key = "test:" .. tostring(index) }
    local edge = {
      from = index, to = index + 1, fromLink = index,
      restLength = lengths and lengths[index] or 1,
      restVector = { x = 0, y = -1, z = 0 },
      terminal = index == points - 1,
    }
    graph.edges[#graph.edges + 1] = edge
    graph.edgesByLink[index] = { edge }
  end
  return graph
end

local function settings(overrides)
  local result = {
    gravitySpace = "local", gravity = { x = 0, y = 0, z = 0 },
    gravityFalloff = 0, pull = 0, spring = 0, damping = 0, mass = 1,
    rootMotionResponse = 0, avatarMotionResponse = 0, maxLinearSpeed = 60,
    joint = { type = "free", axis = { x = 0, y = 1, z = 0 }, angle = 180, angularSpeed = 720 },
  }
  for key, value in pairs(overrides or {}) do result[key] = value end
  return result
end

local function expect(name, callback)
  local ok, result = pcall(callback)
  tests[#tests + 1] = {
    name = name,
    passed = ok and result == true,
    error = not ok and tostring(result) or (type(result) == "string" and result or nil),
  }
end

local function angleBetween(a, b)
  local cosine = (a.x * b.x + a.y * b.y + a.z * b.z) / math.max(magnitude(a) * magnitude(b), 0.000001)
  return math.acos(math.max(-1, math.min(1, cosine)))
end

local function solveOneEdge(kind, angleDegrees, axis, target, current)
  local graph = graphFor(2, { 1 })
  local points = { { x = 0, y = 0, z = 0 }, current }
  local targets = { { x = 0, y = 0, z = 0 }, target }
  constraints.solveAngle(points, graph, function()
    return { joint = { type = kind, angle = angleDegrees, axis = axis } }
  end, targets, 1 / 60)
  return points[2]
end

function tests.run()
  expect("free joint leaves direction unconstrained", function()
    local output = solveOneEdge("free", 15, { x = 0, y = 1, z = 0 },
      { x = 1, y = 0, z = 0 }, { x = 0.6, y = 0.8, z = 0 })
    return near(output.x, 0.6) and near(output.y, 0.8) and near(output.z, 0)
  end)

  expect("cone joint clamps the configured angle", function()
    local output = solveOneEdge("cone", 20, { x = 0, y = 1, z = 0 },
      { x = 0, y = -1, z = 0 }, { x = 0.8, y = -0.6, z = 0 })
    return near(math.deg(angleBetween(output, { x = 0, y = -1, z = 0 })), 20, 0.01)
  end)

  expect("hinge joint stays in its plane and clamps its angle", function()
    local output = solveOneEdge("hinge", 25, { x = 0, y = 1, z = 0 },
      { x = 1, y = 0, z = 0 }, { x = 0.5, y = 0.6, z = 0.6245 })
    return near(output.y, 0, 0.0001)
      and angleBetween(output, { x = 1, y = 0, z = 0 }) <= math.rad(25) + 0.001
  end)

  expect("length projection pins the root and preserves every segment", function()
    local graph = graphFor(7)
    local points = {
      { x = 0, y = 0, z = 0 }, { x = 8, y = 1, z = 0 }, { x = 10, y = 3, z = 0 },
      { x = 12, y = 5, z = 0 }, { x = 14, y = 7, z = 0 }, { x = 16, y = 9, z = 0 },
      { x = 18, y = 11, z = 0 },
    }
    constraints.solveLengths(points, graph, 5, { x = 0, y = 0, z = 0 })
    if not near(points[1].x, 0) or not near(points[1].y, 0) then return false end
    for _, edge in ipairs(graph.edges) do
      local a, b = points[edge.from], points[edge.to]
      local length = math.sqrt((b.x - a.x)^2 + (b.y - a.y)^2 + (b.z - a.z)^2)
      if not near(length, edge.restLength, 0.00001) then return false end
    end
    return true
  end)

  expect("steady player movement exposes root velocity to the physics input", function()
    local position = { x = 0, y = 0, z = 0 }
    local player = { getPos = function() return position end }
    local sampler = motionSampler.new()
    sampler:sample(player, 0, 1 / 20)
    position = { x = 0.25, y = 0, z = 0 }
    local sample = sampler:sample(player, 0, 1 / 20)
    return sample.rootVelocity ~= nil and near(sample.rootVelocity.x, 5, 0.001)
      and near(sample.rootVelocity.y, 0, 0.001) and near(sample.rootVelocity.z, 0, 0.001)
  end)

  expect("steady root motion drags a chain behind the avatar", function()
    local function measureTailLag(alignedToMotion, dragRate)
      local graph = graphFor(5)
      local targets = { { x = 0, y = 0, z = 0 } }
      for index = 1, 4 do
        targets[index + 1] = alignedToMotion
          and { x = -index, y = 0, z = 0 }
          or { x = 0, y = -index, z = 0 }
      end
      local state = solver.newComponentState(graph, targets)
      local options = settings({ gravity = { x = 0, y = 0, z = 0 }, pull = 20, damping = 0,
        rootMotionResponse = 0, motionDrag = dragRate, maxLinearSpeed = 60 })
      for _ = 1, 80 do
        state = solver.step(state, graph, targets, { rootVelocity = { x = 6, y = 0, z = 0 } },
          options, 1 / 20)
      end
      return state.points[5].x - targets[5].x
    end
    local disabledLag = measureTailLag(false, 0)
    local crosswiseLag = measureTailLag(false, 0.25)
    local alignedLag = measureTailLag(true, 0.25)
    if math.abs(disabledLag) > 0.001 then return "zero motion drag changed a stationary chain" end
    if crosswiseLag >= -0.1 then return "steady movement did not pull the chain behind the avatar" end
    if math.abs(alignedLag) >= math.abs(crosswiseLag) * 0.05 then
      return string.format("drag did not weaken as the chain aligned: crosswise %.3f, aligned %.3f",
        crosswiseLag, alignedLag)
    end
    return true
  end)

  expect("environment drag remains tunable at Minecraft sprint speed", function()
    local graph = graphFor(2)
    local targets = { { x = 0, y = 0, z = 0 }, { x = 0, y = 1, z = 0 } }
    local function firstStepOffset(drag)
      local state = solver.newComponentState(graph, targets)
      state = solver.step(state, graph, targets, { rootVelocity = { x = 96, y = 0, z = 0 } },
        settings({ motionDrag = drag, maxLinearSpeed = 60 }), 1 / 60)
      return math.abs(state.points[2].x - targets[2].x)
    end
    local lowDrag = firstStepOffset(0.01)
    local highDrag = firstStepOffset(0.1)
    if lowDrag <= 0 then return "minimum drag did not react to avatar motion" end
    if highDrag <= lowDrag * 2 then
      return string.format("drag values collapsed at game speed: low %.6f, high %.6f", lowDrag, highDrag)
    end
    return true
  end)

  expect("strong environment drag stays finite at sustained game speed", function()
    local graph = graphFor(6)
    local targets = {}
    for index = 1, 6 do
      targets[index] = { x = 0, y = -(index - 1), z = 0 }
      if graph.links[index] then graph.links[index].parentIndex = index - 1 end
    end
    local state = solver.newComponentState(graph, targets)
    local options = settings({ pull = 2, damping = 2, motionDrag = 2, maxLinearSpeed = 60 })
    for tick = 1, 180 do
      local velocity = tick <= 120 and 96 or 0
      state = solver.step(state, graph, targets, { rootVelocity = { x = velocity, y = 0, z = 0 } },
        options, 1 / 60)
      for _, point in ipairs(state.points) do
        if not finiteVector(point) then return "drag produced a non-finite point at tick " .. tostring(tick) end
      end
    end
    for _, edge in ipairs(graph.edges) do
      local delta = { x = state.points[edge.to].x - state.points[edge.from].x,
        y = state.points[edge.to].y - state.points[edge.from].y,
        z = state.points[edge.to].z - state.points[edge.from].z }
      if not near(magnitude(delta), edge.restLength, 0.001) then return "drag changed a chain link length" end
    end
    return true
  end)

  expect("branched chain links keep independent motion settings", function()
    local graph = {
      pointCount = 5,
      links = {
        { index = 1, key = "branch:root", parentIndex = nil },
        { index = 2, key = "branch:left", parentIndex = 1 },
        { index = 3, key = "branch:right", parentIndex = 1 },
      },
      edges = {
        { from = 1, to = 2, fromLink = 1, restLength = 1, restVector = { x = 0, y = -1, z = 0 } },
        { from = 1, to = 3, fromLink = 1, restLength = 1, restVector = { x = 0, y = 1, z = 0 } },
        { from = 2, to = 4, fromLink = 2, restLength = 1, restVector = { x = 0, y = -1, z = 0 }, terminal = true },
        { from = 3, to = 5, fromLink = 3, restLength = 1, restVector = { x = 0, y = 1, z = 0 }, terminal = true },
      },
      edgesByLink = {},
    }
    for _, edge in ipairs(graph.edges) do
      graph.edgesByLink[edge.fromLink] = graph.edgesByLink[edge.fromLink] or {}
      graph.edgesByLink[edge.fromLink][#graph.edgesByLink[edge.fromLink] + 1] = edge
    end
    local targets = {
      { x = 0, y = 0, z = 0 }, { x = 0, y = -1, z = 0 }, { x = 0, y = 1, z = 0 },
      { x = 0, y = -2, z = 0 }, { x = 0, y = 2, z = 0 },
    }
    local state = solver.newComponentState(graph, targets)
    local options = settings({ gravity = { x = 0, y = 0, z = 0 }, pull = 0, damping = 2, maxLinearSpeed = 24 })
    local overrides = { ["branch:left"] = { motionDrag = 0.8 }, ["branch:right"] = { motionDrag = 0 } }
    for _ = 1, 120 do
      state = solver.step(state, graph, targets, { rootVelocity = { x = 6, y = 0, z = 0 } },
        options, 1 / 60, nil, nil, overrides)
    end
    if state.points[4].x >= -0.1 then return "left branch did not trail" end
    if math.abs(state.points[5].x) > 0.001 then return "left branch settings leaked into the right branch" end
    for _, edge in ipairs(graph.edges) do
      local delta = { x = state.points[edge.to].x - state.points[edge.from].x,
        y = state.points[edge.to].y - state.points[edge.from].y,
        z = state.points[edge.to].z - state.points[edge.from].z }
      if not near(magnitude(delta), edge.restLength, 0.001) then return "branch segment length changed" end
    end
    return true
  end)

  expect("motion drag is weaker along a link than across it", function()
    local function measureDrag(linkDirection)
      local graph = {
        pointCount = 2,
        links = {
          { index = 1, key = "root" },
          { index = 2, key = "test:link", parentIndex = 1 },
        },
        edges = {}, edgesByLink = {},
      }
      local targets = { { x = 0, y = 0, z = 0 }, linkDirection }
      local state = solver.newComponentState(graph, targets)
      state = solver.step(state, graph, targets, { rootVelocity = { x = 6, y = 0, z = 0 } },
        settings({ motionDrag = 1, maxLinearSpeed = 60 }), 1 / 20)
      local point = state.points[2]
      return math.sqrt((point.x - linkDirection.x)^2 + (point.y - linkDirection.y)^2
        + (point.z - linkDirection.z)^2)
    end
    local along = measureDrag({ x = 1, y = 0, z = 0 })
    local across = measureDrag({ x = 0, y = 1, z = 0 })
    if across <= along * 4 then
      return string.format("orientation did not reduce axial drag enough: along %.6f, across %.6f", along, across)
    end
    return true
  end)

  expect("transverse drag does not grow when axial speed is added", function()
    local function measureAcross(rootVelocity)
      local graph = {
        pointCount = 2,
        links = {
          { index = 1, key = "root" },
          { index = 2, key = "test:link", parentIndex = 1 },
        },
        edges = {}, edgesByLink = {},
      }
      local targets = { { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 } }
      local state = solver.newComponentState(graph, targets)
      state = solver.step(state, graph, targets, { rootVelocity = rootVelocity },
        settings({ motionDrag = 1 }), 1 / 60)
      return math.abs(state.points[2].y - targets[2].y)
    end
    local transverseOnly = measureAcross({ x = 0, y = 6, z = 0 })
    local mixedFlow = measureAcross({ x = 6, y = 6, z = 0 })
    return near(transverseOnly, mixedFlow, 0.00001)
  end)

  expect("bend stiffness smooths a folded chain while preserving segment lengths", function()
    local graph = graphFor(4)
    graph.links[2].parentIndex, graph.links[3].parentIndex = 1, 2
    local targets = {
      { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 },
      { x = 2, y = 0, z = 0 }, { x = 3, y = 0, z = 0 },
    }
    local function run(stiffness)
      local state = solver.newComponentState(graph, targets)
      state.points = {
        { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 },
        { x = 1, y = 1, z = 0 }, { x = 0, y = 1, z = 0 },
      }
      state.previousPoints = {
        { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 },
        { x = 1, y = 1, z = 0 }, { x = 0, y = 1, z = 0 },
      }
      local options = settings({ bendStiffness = stiffness, maxLinearSpeed = 60 })
      for _ = 1, 60 do state = solver.step(state, graph, targets, {}, options, 1 / 60) end
      local bend = 0
      for index = 2, #state.points - 1 do
        local incoming = {
          x = state.points[index].x - state.points[index - 1].x,
          y = state.points[index].y - state.points[index - 1].y,
          z = state.points[index].z - state.points[index - 1].z,
        }
        local outgoing = {
          x = state.points[index + 1].x - state.points[index].x,
          y = state.points[index + 1].y - state.points[index].y,
          z = state.points[index + 1].z - state.points[index].z,
        }
        bend = bend + angleBetween(incoming, outgoing)
      end
      for _, edge in ipairs(graph.edges) do
        local a, b = state.points[edge.from], state.points[edge.to]
        if not near(magnitude({ x = b.x - a.x, y = b.y - a.y, z = b.z - a.z }), edge.restLength, 0.001) then
          return nil, "bend projection changed a segment length"
        end
      end
      return bend
    end
    local freeBend = run(0)
    local stiffBend, reason = run(18)
    if not stiffBend then return reason end
    if freeBend < math.rad(150) then return "unconstrained control did not retain its folded shape" end
    if stiffBend >= freeBend * 0.35 then
      return string.format("bend stiffness did not relax the fold enough: free %.3f, stiff %.3f", freeBend, stiffBend)
    end
    return true
  end)

  expect("bend stiffness preserves the animated chain curvature", function()
    local graph = graphFor(3)
    graph.links[2].parentIndex = 1
    local targets = {
      { x = 0, y = 0, z = 0 }, { x = 0, y = -1, z = 0 }, { x = 1, y = -1, z = 0 },
    }
    local state = solver.newComponentState(graph, targets)
    state.points = {
      { x = 0, y = 0, z = 0 }, { x = 0, y = -1, z = 0 }, { x = 0, y = -2, z = 0 },
    }
    state.previousPoints = {
      { x = 0, y = 0, z = 0 }, { x = 0, y = -1, z = 0 }, { x = 0, y = -2, z = 0 },
    }
    local options = settings({ bendStiffness = 18, maxLinearSpeed = 60 })
    for _ = 1, 60 do state = solver.step(state, graph, targets, {}, options, 1 / 60) end
    local incoming = {
      x = state.points[2].x - state.points[1].x,
      y = state.points[2].y - state.points[1].y,
      z = state.points[2].z - state.points[1].z,
    }
    local outgoing = {
      x = state.points[3].x - state.points[2].x,
      y = state.points[3].y - state.points[2].y,
      z = state.points[3].z - state.points[2].z,
    }
    return math.abs(math.deg(angleBetween(incoming, outgoing)) - 90) < 5
  end)

  expect("movement drag respects pose pull and returns a loose chain", function()
    local graph = graphFor(6)
    for index = 2, 5 do graph.links[index].parentIndex = index - 1 end
    local targets = {
      { x = 0, y = 0, z = 0 },
      { x = 0, y = -1, z = 0 },
      { x = 1, y = -1, z = 0 },
      { x = 2, y = -1, z = 0 },
      { x = 2, y = 0, z = 0 },
      { x = 1, y = 0, z = 0 },
    }
    local function totalBend(points)
      local total = 0
      for index = 2, #points - 1 do
        local incoming = { x = points[index].x - points[index - 1].x,
          y = points[index].y - points[index - 1].y, z = points[index].z - points[index - 1].z }
        local outgoing = { x = points[index + 1].x - points[index].x,
          y = points[index + 1].y - points[index].y, z = points[index + 1].z - points[index].z }
        total = total + angleBetween(incoming, outgoing)
      end
      return total
    end
    local initialBend = totalBend(targets)
    local function run(pull, bendStiffness, stopAfterMovement)
      local state = solver.newComponentState(graph, targets)
      local options = settings({ gravity = { x = 0, y = 0, z = 0 }, pull = pull,
        damping = 2, motionDrag = 0.8, bendStiffness = bendStiffness, maxLinearSpeed = 24 })
      for _ = 1, 180 do
        state = solver.step(state, graph, targets, { rootVelocity = { x = 6, y = 0, z = 0 } }, options, 1 / 60)
      end
      local movingBend = totalBend(state.points)
      local movingTip = state.points[#state.points].x
      for _, edge in ipairs(graph.edges) do
        local a, b = state.points[edge.from], state.points[edge.to]
        local segmentLength = math.sqrt((b.x - a.x)^2 + (b.y - a.y)^2 + (b.z - a.z)^2)
        if math.abs(segmentLength - edge.restLength) > 0.001 then
          return nil, nil, nil, "movement changed a link length"
        end
      end
      local rmsError = nil
      if stopAfterMovement then
        local squaredError = 0
        for _ = 1, 600 do
          state = solver.step(state, graph, targets, { rootVelocity = { x = 0, y = 0, z = 0 } }, options, 1 / 60)
        end
        for index, point in ipairs(state.points) do
          local dx, dy, dz = point.x - targets[index].x, point.y - targets[index].y, point.z - targets[index].z
          squaredError = squaredError + dx * dx + dy * dy + dz * dz
        end
        rmsError = math.sqrt(squaredError / #state.points)
      end
      return movingBend, movingTip, rmsError
    end
    local responsiveBend, responsiveTip, settleError = run(0.5, 0.75, true)
    local poseLockedBend, poseLockedTip = run(20, 0, false)
    if responsiveBend >= initialBend * 0.75 or responsiveTip >= 0 then
      return string.format("low pull failed to trail: bend %.1f°, tipX %.2f", math.deg(responsiveBend), responsiveTip)
    end
    if poseLockedBend <= initialBend * 0.75 or poseLockedTip <= 0 then
      return "high pose pull no longer holds the authored curl"
    end
    if not settleError or settleError >= 0.2 then
      return string.format("responsive chain did not settle near its pose: RMS %.3f", settleError or -1)
    end
    return true
  end)

  expect("pull slider preserves fine low-range values", function()
    local spec = { min = 0, max = 500, step = 0.05, decimals = 2, curve = 3 }
    return near(physicsUI.mapSliderValue(spec, 0.1), 0.5, 0.001)
      and near(physicsUI.mapSliderRatio(spec, 0.5), 0.1, 0.001)
      and near(physicsUI.parameterNudge({ step = 0.05, nudge = 1 }), 1, 0.001)
  end)

  expect("saved configurations receive and retain the motion-drag setting", function()
    local clean = configApi.validate({ schema = 1, components = { {
      id = "legacy", name = "Legacy", rootPath = { { name = "root", sameNameIndex = 1 } },
      settings = { pull = 60, bendStiffness = 3 }, linkOverrides = { ["test-link"] = { motionDrag = 0.75, bendStiffness = 12 } },
    } } })
    local component = clean.components[1]
    return component and near(component.settings.motionDrag, 0.25)
      and near(component.settings.bendStiffness, 3)
      and near(configApi.effective(component, "test-link").motionDrag, 0.75)
      and near(configApi.effective(component, "test-link").bendStiffness, 12)
  end)

  expect("bundled preset loads automatically unless local Figura settings exist", function()
    local previousConfig, previousAvatar = config, avatar
    local previousPreset = package.loaded.physics_bone_preset
    local bundled = { schema = 1, components = { {
      id = "bundled", name = "Bundled", rootPath = { { name = "tail", sameNameIndex = 1 } },
      settings = { pull = 0.5 },
    } } }
    local localProfile = { schema = 1, components = { {
      id = "local", name = "Local", rootPath = { { name = "ear", sameNameIndex = 1 } },
      settings = { pull = 12 },
    } } }
    package.loaded.physics_bone_preset = bundled
    config = {
      setName = function() end,
      load = function() return nil end,
    }
    avatar = { getName = function() return "Preset Test" end }
    local fromBundle = configApi.load()
    config.load = function() return localProfile end
    local fromLocal = configApi.load()
    local imported = configApi.importBundledPreset()
    config, avatar = previousConfig, previousAvatar
    package.loaded.physics_bone_preset = previousPreset
    return fromBundle.components[1].id == "bundled"
      and near(fromBundle.components[1].settings.pull, 0.5)
      and fromLocal.components[1].id == "local"
      and near(fromLocal.components[1].settings.pull, 12)
      and imported and imported.components[1].id == "bundled"
  end)

  expect("preset export writes validated JSON and a loadable Lua module", function()
    local previousFile, previousAvatar, previousToJson, previousParseJson = file, avatar, toJson, parseJson
    local writes, directories = {}, {}
    local jsonText = '{"schema":1,"components":[]}'
    file = {
      allowed = function() return true end,
      isPathAllowed = function() return true end,
      mkdirs = function(_, path) directories[path] = true end,
      isDirectory = function(_, path) return directories[path] == true end,
      writeString = function(_, path, value) writes[path] = value end,
      exists = function(_, path) return writes[path] ~= nil end,
    }
    avatar = { getName = function() return "Preset Test" end }
    toJson = function() return jsonText end
    parseJson = function(source)
      if source == jsonText then return { schema = 1, components = {} } end
      error("unexpected JSON content passed to parseJson")
    end
    local ok, folder = configApi.exportPreset({ schema = 1, components = {} })
    local exportedJson = ok and writes[folder .. "/physics_bone_preset.json"] or nil
    local luaText = ok and writes[folder .. "/physics_bone_preset.lua"] or nil
    local compiler = loadstring or load
    local compiled, compileError
    if type(luaText) == "string" and type(compiler) == "function" then compiled, compileError = compiler(luaText) end
    local moduleOk, module = false, nil
    if compiled then moduleOk, module = pcall(compiled) end
    file, avatar, toJson, parseJson = previousFile, previousAvatar, previousToJson, previousParseJson
    if not ok then return "export rejected the Figura File API mock: " .. tostring(folder) end
    if not compiled then return "generated Lua preset did not compile: " .. tostring(compileError) end
    return exportedJson == jsonText and moduleOk and type(module) == "table"
      and module.schema == 1 and type(module.components) == "table"
      and writes[folder .. "/physics_bone_preset.json"] ~= nil
      and writes[folder .. "/physics_bone_preset.lua"] ~= nil
  end)

  expect("child link inherits a parent's animated physical bend only once", function()
    local graph = {
      pointCount = 3,
      links = {
        { index = 1, key = "test:1", parentIndex = nil },
        { index = 2, key = "test:2", parentIndex = 1 },
      },
      edges = {
        { from = 1, to = 2, fromLink = 1, restVector = { x = 0, y = -1, z = 0 }, restLength = 1 },
        { from = 2, to = 3, fromLink = 2, restVector = { x = 0, y = -1, z = 0 }, restLength = 1, terminal = true },
      },
      edgesByLink = {},
    }
    graph.edgesByLink[1] = { graph.edges[1] }
    graph.edgesByLink[2] = { graph.edges[2] }
    local parentAnimation = math.rad(30)
    local childAnimation = math.rad(10)
    local parentPhysicalBend = math.rad(20)
    local childPhysicalBend = math.rad(10)
    local function rotationZ(angle)
      return {
        { math.cos(angle), -math.sin(angle), 0 },
        { math.sin(angle), math.cos(angle), 0 },
        { 0, 0, 1 },
      }
    end
    local parentAnimationFrame = rotationZ(parentAnimation)
    local childAnimationFrame = rotationZ(parentAnimation + childAnimation)
    local function direction(angle)
      return { x = math.sin(angle), y = -math.cos(angle), z = 0 }
    end
    local targetParentDirection = direction(parentAnimation)
    local targetChildDirection = direction(parentAnimation + childAnimation)
    local solvedParentDirection = direction(parentAnimation + parentPhysicalBend)
    local solvedChildDirection = direction(parentAnimation + childAnimation + parentPhysicalBend + childPhysicalBend)
    local targets = {
      { x = 0, y = 0, z = 0 },
      targetParentDirection,
      { x = targetParentDirection.x + targetChildDirection.x,
        y = targetParentDirection.y + targetChildDirection.y, z = 0 },
    }
    local options = settings({
      gravity = { x = 0, y = 0, z = 0 }, pull = 0, damping = 0, maxLinearSpeed = 200,
      joint = { type = "free", axis = { x = 0, y = 1, z = 0 }, angle = 180, angularSpeed = 7200 },
    })
    local identity = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
    local state = solver.newComponentState(graph, targets)
    state.points[2] = solvedParentDirection
    state.points[3] = { x = solvedParentDirection.x + solvedChildDirection.x,
      y = solvedParentDirection.y + solvedChildDirection.y, z = 0 }
    local _, offsets = solver.step(state, graph, targets, {}, options, 1 / 240,
      identity, { identity, parentAnimationFrame }, nil, { parentAnimationFrame, childAnimationFrame })
    local parentOffset, childOffset = magnitude(offsets[1]), magnitude(offsets[2])
    if math.abs(parentOffset - parentPhysicalBend) < math.rad(0.1)
      and math.abs(childOffset - childPhysicalBend) < math.rad(0.1) then return true end
    return string.format("parent %.2f° child %.2f°; expected %.2f° / %.2f°",
      math.deg(parentOffset), math.deg(childOffset), math.deg(parentPhysicalBend), math.deg(childPhysicalBend))
  end)

  expect("additive Euler offsets preserve child directions under compound animation", function()
    local function eulerMatrix(rotation)
      local sx, cx = math.sin(rotation.x), math.cos(rotation.x)
      local sy, cy = math.sin(rotation.y), math.cos(rotation.y)
      local sz, cz = math.sin(rotation.z), math.cos(rotation.z)
      return {
        { cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx },
        { sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx },
        { -sy, cy * sx, cy * cx },
      }
    end
    local function multiply(a, b)
      local result = { {}, {}, {} }
      for row = 1, 3 do for column = 1, 3 do
        result[row][column] = a[row][1] * b[1][column]
          + a[row][2] * b[2][column] + a[row][3] * b[3][column]
      end end
      return result
    end
    local function rotate(matrix, point)
      return {
        x = matrix[1][1] * point.x + matrix[1][2] * point.y + matrix[1][3] * point.z,
        y = matrix[2][1] * point.x + matrix[2][2] * point.y + matrix[2][3] * point.z,
        z = matrix[3][1] * point.x + matrix[3][2] * point.y + matrix[3][3] * point.z,
      }
    end
    local function axisAngleMatrix(rotation)
      local angle = magnitude(rotation)
      if angle < 0.000001 then return eulerMatrix({ x = 0, y = 0, z = 0 }) end
      local x, y, z = rotation.x / angle, rotation.y / angle, rotation.z / angle
      local c, s, t = math.cos(angle), math.sin(angle), 1 - math.cos(angle)
      return {
        { t * x * x + c, t * x * y - s * z, t * x * z + s * y },
        { t * x * y + s * z, t * y * y + c, t * y * z - s * x },
        { t * x * z - s * y, t * y * z + s * x, t * z * z + c },
      }
    end
    local function atan2(y, x)
      if math.atan2 then return math.atan2(y, x) end
      if x > 0 then return math.atan(y / x) end
      if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
      if x < 0 then return math.atan(y / x) - math.pi end
      if y > 0 then return math.pi / 2 end
      if y < 0 then return -math.pi / 2 end
      return 0
    end
    local function matrixEuler(matrix)
      local pitch = math.asin(math.max(-1, math.min(1, -matrix[3][1])))
      return {
        x = atan2(matrix[3][2], matrix[3][3]), y = pitch,
        z = atan2(matrix[2][1], matrix[1][1]),
      }
    end
    local function add(a, b) return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end
    local down = { x = 0, y = -1, z = 0 }
    local parentAnimation = { x = math.rad(20), y = math.rad(-15), z = math.rad(30) }
    local childAnimation = { x = math.rad(-10), y = math.rad(25), z = math.rad(5) }
    local parentBend = { x = math.rad(15), y = 0, z = 0 }
    local childBend = { x = math.rad(-12), y = 0, z = 0 }
    local identity = eulerMatrix({ x = 0, y = 0, z = 0 })
    local parentFrame = eulerMatrix(parentAnimation)
    local childFrame = multiply(parentFrame, eulerMatrix(childAnimation))
    local parentSolvedFrame = eulerMatrix(add(parentAnimation, parentBend))
    local childSolvedFrame = multiply(parentSolvedFrame, eulerMatrix(add(childAnimation, childBend)))
    local targetParentDirection = rotate(parentFrame, down)
    local targetChildDirection = rotate(childFrame, down)
    local solvedParentDirection = rotate(parentSolvedFrame, down)
    local solvedChildDirection = rotate(childSolvedFrame, down)
    local graph = {
      pointCount = 3,
      links = { { index = 1, parentIndex = nil }, { index = 2, parentIndex = 1 } },
      edges = {
        { from = 1, to = 2, fromLink = 1, restVector = down, restLength = 1 },
        { from = 2, to = 3, fromLink = 2, restVector = down, restLength = 1, terminal = true },
      },
      edgesByLink = {},
    }
    graph.edgesByLink[1], graph.edgesByLink[2] = { graph.edges[1] }, { graph.edges[2] }
    local targets = {
      { x = 0, y = 0, z = 0 },
      targetParentDirection,
      { x = targetParentDirection.x + targetChildDirection.x,
        y = targetParentDirection.y + targetChildDirection.y,
        z = targetParentDirection.z + targetChildDirection.z },
    }
    local state = solver.newComponentState(graph, targets)
    state.points[2] = solvedParentDirection
    state.points[3] = {
      x = solvedParentDirection.x + solvedChildDirection.x,
      y = solvedParentDirection.y + solvedChildDirection.y,
      z = solvedParentDirection.z + solvedChildDirection.z,
    }
    local options = settings({ gravity = { x = 0, y = 0, z = 0 }, pull = 0, damping = 0,
      joint = { type = "free", axis = { x = 0, y = 1, z = 0 }, angle = 180, angularSpeed = 7200 } })
    local _, offsets = solver.step(state, graph, targets, {}, options, 1 / 240,
      identity, { identity, parentFrame }, nil, { parentFrame, childFrame })
    local parentOffsetEuler = matrixEuler(axisAngleMatrix(offsets[1]))
    local childOffsetEuler = matrixEuler(axisAngleMatrix(offsets[2]))
    local actualParentFrame = eulerMatrix(add(parentAnimation, parentOffsetEuler))
    local actualChildFrame = multiply(actualParentFrame, eulerMatrix(add(childAnimation, childOffsetEuler)))
    local actualParentDirection = rotate(actualParentFrame, down)
    local actualChildDirection = rotate(actualChildFrame, down)
    return angleBetween(actualParentDirection, solvedParentDirection) < 0.001
      and angleBetween(actualChildDirection, solvedChildDirection) < 0.001
  end)

  expect("independent component states do not share solver points", function()
    local graphA, graphB = graphFor(3), graphFor(3)
    local targets = {
      { x = 0, y = 0, z = 0 }, { x = 0, y = -1, z = 0 }, { x = 0, y = -2, z = 0 },
    }
    local stateA, stateB = solver.newComponentState(graphA, targets), solver.newComponentState(graphB, targets)
    if stateA.points == stateB.points or stateA.points[2] == stateB.points[2] then return false end
    local settingsA = settings({ rootMotionResponse = 1 })
    local settingsB = settings({ rootMotionResponse = 0 })
    stateA = solver.step(stateA, graphA, targets, { rootAcceleration = { x = 10, y = 0, z = 0 } },
      settingsA, 1 / 20)
    stateB = solver.step(stateB, graphB, targets, { rootAcceleration = { x = 10, y = 0, z = 0 } },
      settingsB, 1 / 20)
    return stateA.points ~= stateB.points and math.abs(stateA.points[2].x - stateB.points[2].x) > 0.0001
      and near(stateB.points[2].x, 0, 0.0001)
  end)

  expect("world gravity rotates into a tilted parent frame", function()
    local graph = graphFor(2)
    local targets = { { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 } }
    local state = solver.newComponentState(graph, targets)
    local options = settings({ gravitySpace = "world", gravity = { x = 0, y = -9.81, z = 0 } })
    local frame = { { 1, 0, 0 }, { 0, 0, -1 }, { 0, 1, 0 } }
    state = solver.step(state, graph, targets, {}, options, 1 / 20, frame)
    local passed = state.points[2].z < -0.0001 and near(state.points[2].x, 1, 0.001)
    if not passed then
      return "world tilt position x=" .. tostring(state.points[2].x) .. " y=" .. tostring(state.points[2].y)
        .. " z=" .. tostring(state.points[2].z)
    end
    return true
  end)

  expect("local gravity remains in model coordinates", function()
    local graph = graphFor(2)
    local targets = { { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 } }
    local state = solver.newComponentState(graph, targets)
    local options = settings({ gravitySpace = "local", gravity = { x = 0, y = -9.81, z = 0 } })
    local frame = { { 1, 0, 0 }, { 0, 0, -1 }, { 0, 1, 0 } }
    state = solver.step(state, graph, targets, {}, options, 1 / 20, frame)
    return state.points[2].y < -0.0001 and near(state.points[2].z, 0, 0.001)
  end)

  expect("high impulse remains finite and respects link lengths", function()
    local graph = graphFor(7)
    local targets = {
      { x = 0, y = 0, z = 0 }, { x = 0, y = -1, z = 0 }, { x = 0, y = -2, z = 0 },
      { x = 0, y = -3, z = 0 }, { x = 0, y = -4, z = 0 }, { x = 0, y = -5, z = 0 },
      { x = 0, y = -6, z = 0 },
    }
    local state = solver.newComponentState(graph, targets)
    state = solver.step(state, graph, targets, { rootAcceleration = { x = 10000, y = -3000, z = 5000 } },
      settings({ maxLinearSpeed = 24 }), 1 / 20)
    for _, point in ipairs(state.points) do if not finiteVector(point) then return false end end
    for _, edge in ipairs(graph.edges) do
      if not near(magnitude({
        x = state.points[edge.to].x - state.points[edge.from].x,
        y = state.points[edge.to].y - state.points[edge.from].y,
        z = state.points[edge.to].z - state.points[edge.from].z,
      }), edge.restLength, 0.0001) then return false end
    end
    return true
  end)

  expect("reset recreates an independent neutral chain state", function()
    local graph = graphFor(3)
    local targets = { { x = 0, y = 0, z = 0 }, { x = 0, y = -1, z = 0 }, { x = 0, y = -2, z = 0 } }
    local state = solver.newComponentState(graph, targets)
    state.points[2].x = 5
    state.offsets[1].z = 1
    local reset = solver.newComponentState(graph, targets)
    return near(reset.points[2].x, 0) and near(reset.offsets[1].z, 0)
      and near(state.points[2].x, 5)
  end)

  expect("collision query diagnostics survive multiple fixed substeps", function()
    local graph = graphFor(2)
    local targets = { { x = 0, y = 0, z = 0 }, { x = 0, y = -1, z = 0 } }
    local options = settings({ collision = {
      enabled = true, avatar = false, world = true, self = false,
      radius = 0.1, friction = 0, restitution = 0, iterations = 1,
      maxBlockQueries = 64, maxSelfPairs = 0,
    } })
    local queryCalls, newlyQueriedBlocks = 0, 0
    local context = {
      enabled = true, frameAvailable = true, worldScale = 1,
      rootOriginWorld = { x = 0, y = 0, z = 0 }, avatarShapes = {},
      toWorldPoint = function(point) return point end,
      toParentVector = function(point) return point end,
      queryWorld = function()
        queryCalls = queryCalls + 1
        if newlyQueriedBlocks == 0 then newlyQueriedBlocks = 1; return {}, 1, false, true end
        return {}, 0, false, true
      end,
    }
    local state = solver.newComponentState(graph, targets)
    state = solver.step(state, graph, targets, {}, options, 1 / 20, nil, nil, nil, nil, context)
    return queryCalls >= 2 and newlyQueriedBlocks == 1
      and (state.collisionDiagnostics.worldQueries or 0) >= newlyQueriedBlocks
  end)

  expect("component self-collision setting reaches the fixed-step solver", function()
    local graph = graphFor(5)
    local targets = {
      { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }, { x = 1, y = 1, z = 0 },
      { x = 0, y = 1, z = 0 }, { x = 0.1, y = 0.1, z = 0 },
    }
    local options = settings({ collision = {
      enabled = true, avatar = false, world = false, self = true,
      radius = 0.5, friction = 0, restitution = 0, iterations = 1,
      maxBlockQueries = 0, maxSelfPairs = 64,
    } })
    local zero = { x = 0, y = 0, z = 0 }
    local context = {
      enabled = true, frameAvailable = true, worldScale = 1, rootOriginWorld = zero, avatarShapes = {},
      toWorldPoint = function(point) return point end,
      toParentVector = function(point) return point end,
    }
    local state = solver.newComponentState(graph, targets)
    state = solver.step(state, graph, targets, {}, options, 1 / 20, nil, nil, nil, nil, context)
    local a, b = state.points[2], state.points[5]
    local separation = math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2 + (a.z - b.z)^2)
    return (state.collisionDiagnostics.contacts or 0) > 0 and separation >= 0.99
  end)

  local passed, failed = 0, 0
  local checks = {}
  for _, test in ipairs(tests) do
    if test.passed then passed = passed + 1 else failed = failed + 1 end
    checks[#checks + 1] = test
  end
  return { passed = passed, failed = failed, checks = checks }
end

return tests
