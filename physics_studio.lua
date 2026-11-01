local physicsRegistry = require("physics_registry")
local physicsConfig = require("physics_config")
local physicsInput = require("physics_input")
local physicsCore = require("physics_core")
local physicsChain = require("physics_chain")
local physicsGizmos = require("physics_gizmos")
local physicsUI = require("physics_ui")

local physicsStudio = {
  initialized = false,
  rootPart = nil,
  registry = nil,
  savedConfig = nil,
  draftConfig = nil,
  runtimeChains = {},
  input = physicsInput.new(),
  ui = nil,
  gizmos = physicsGizmos.new(),
  lastInput = nil,
  alive = true,
  deathAlpha = 1,
  initErrorKey = nil,
  tickCount = 0,
}

local DT = 1 / 20
local EVENT_NAME = "figura.physics_studio"

local function safeCall(object, method, ...)
  if not object then return nil end
  local fn = object[method]
  if type(fn) ~= "function" then return nil end
  if select("#", ...) == 0 then
    local ok, result = pcall(fn, object)
    if ok then return result end
    return nil
  end
  local args = { ... }
  local ok, result = pcall(fn, object, (table.unpack or unpack)(args))
  if ok then return result end
  return nil
end

local function emitLog(message)
  if type(log) == "function" then pcall(log, "[Physics Studio] " .. tostring(message)) end
end

local function vector(x, y, z)
  return { x = x or 0, y = y or 0, z = z or 0 }
end

local function vectorFrom(value)
  if not value then return vector(0, 0, 0) end
  local x, y, z = tonumber(value.x) or 0, tonumber(value.y) or 0, tonumber(value.z) or 0
  if x ~= x or y ~= y or z ~= z or x == math.huge or y == math.huge or z == math.huge then
    return vector(0, 0, 0)
  end
  return vector(x, y, z)
end

local function vectorSubtract(a, b)
  return vector(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function vectorAdd(a, b)
  return vector(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function vectorLength(value)
  return math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
end

local function identity()
  return { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
end

local function resetIdentity(matrix)
  for row = 1, 3 do
    for column = 1, 3 do matrix[row][column] = row == column and 1 or 0 end
  end
end

local function multiplyMatrixInto(result, a, b)
  for row = 1, 3 do
    for column = 1, 3 do
      local value = 0
      for index = 1, 3 do value = value + a[row][index] * b[index][column] end
      result[row][column] = value
    end
  end
end

local function transformVector(matrix, value)
  return vector(
    matrix[1][1] * value.x + matrix[1][2] * value.y + matrix[1][3] * value.z,
    matrix[2][1] * value.x + matrix[2][2] * value.y + matrix[2][3] * value.z,
    matrix[3][1] * value.x + matrix[3][2] * value.y + matrix[3][3] * value.z)
end

local function transformTransposeVector(matrix, value)
  return
    matrix[1][1] * value.x + matrix[2][1] * value.y + matrix[3][1] * value.z,
    matrix[1][2] * value.x + matrix[2][2] * value.y + matrix[3][2] * value.z,
    matrix[1][3] * value.x + matrix[2][3] * value.y + matrix[3][3] * value.z
end

local function rotationMatrixInto(rotation, result)
  local x, y, z = math.rad(rotation.x), math.rad(rotation.y), math.rad(rotation.z)
  local sx, cx, sy, cy, sz, cz = math.sin(x), math.cos(x), math.sin(y), math.cos(y), math.sin(z), math.cos(z)
  -- Figura's rotation4 uses ZYX order; this is Rz * Ry * Rx.
  result[1][1], result[1][2], result[1][3] = cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx
  result[2][1], result[2][2], result[2][3] = sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx
  result[3][1], result[3][2], result[3][3] = -sy, cy * sx, cy * cx
  return result
end

local function rotationVectorToEuler(rx, ry, rz)
  local angle = math.sqrt(rx * rx + ry * ry + rz * rz)
  if angle < 0.000001 then return 0, 0, 0 end
  local ax, ay, az = rx / angle, ry / angle, rz / angle
  local c, s, t = math.cos(angle), math.sin(angle), 1 - math.cos(angle)
  local r11 = t * ax * ax + c
  local r21 = t * ax * ay + s * az
  local r31 = t * ax * az - s * ay
  local r32 = t * ay * az + s * ax
  local r33 = t * az * az + c
  local y = math.asin(math.max(-1, math.min(1, -r31)))
  local x = math.atan2 and math.atan2(r32, r33) or math.atan(r32 / (r33 == 0 and 0.000001 or r33))
  local z = math.atan2 and math.atan2(r21, r11) or math.atan(r21 / (r11 == 0 and 0.000001 or r11))
  return math.deg(x), math.deg(y), math.deg(z)
end

local function keyForPath(path)
  return physicsChain.pathKey(path)
end

local function sameKeys(a, b)
  if #(a or {}) ~= #(b or {}) then return false end
  for index, key in ipairs(a or {}) do if key ~= b[index] then return false end end
  return true
end

local function linksSignature(keys)
  return table.concat(keys or {}, "|")
end

local function readAnimatedRotation(runtime, index)
  local part = runtime.linkNodes[index] and runtime.linkNodes[index].part
  local current = vectorFrom(safeCall(part, "getTrueRot"))
  local applied = runtime.appliedEuler[index] or vector(0, 0, 0)
  local result = runtime.animatedRotations[index] or vector(0, 0, 0)
  result.x, result.y, result.z = current.x - applied.x, current.y - applied.y, current.z - applied.z
  return result
end

local function readAnimatedPosition(node)
  return vectorFrom(safeCall(node and node.part, "getTruePos"))
end

local function buildAnimatedBase(runtime)
  local count = #runtime.linkNodes
  local points = runtime.basePoints or {}
  runtime.basePoints = points
  local firstPoint = points[1] or vector(0, 0, 0)
  firstPoint.x, firstPoint.y, firstPoint.z = 0, 0, 0
  points[1] = firstPoint

  local animatedFrame = runtime.animatedFrame or identity()
  local animatedFrameScratch = runtime.animatedFrameScratch or identity()
  local poseFrame = runtime.poseFrame or identity()
  local poseFrameScratch = runtime.poseFrameScratch or identity()
  local rotationScratch = runtime.rotationScratch or identity()
  resetIdentity(animatedFrame)
  resetIdentity(animatedFrameScratch)
  resetIdentity(poseFrame)
  resetIdentity(poseFrameScratch)
  runtime.parentFrames = runtime.parentFrames or {}
  runtime.animatedRotations = runtime.animatedRotations or {}

  for index = 1, count do
    local node = runtime.linkNodes[index]
    local animatedRotation = readAnimatedRotation(runtime, index)
    runtime.animatedRotations[index] = animatedRotation
    local parentFrame = runtime.parentFrames[index]
    if not parentFrame then
      parentFrame = identity()
      runtime.parentFrames[index] = parentFrame
    end
    for row = 1, 3 do
      for column = 1, 3 do parentFrame[row][column] = poseFrame[row][column] end
    end
    rotationMatrixInto(animatedRotation, rotationScratch)
    multiplyMatrixInto(animatedFrameScratch, animatedFrame, rotationScratch)
    animatedFrame, animatedFrameScratch = animatedFrameScratch, animatedFrame
    multiplyMatrixInto(poseFrameScratch, poseFrame, rotationScratch)
    poseFrame, poseFrameScratch = poseFrameScratch, poseFrame

    local delta
    if index < count then
      local pivotDelta = runtime.pivotDeltas and runtime.pivotDeltas[index]
      if pivotDelta then
        delta = pivotDelta
      else
        local currentPivot = vectorFrom(safeCall(node.part, "getPivot"))
        local nextPivot = vectorFrom(safeCall(runtime.linkNodes[index + 1].part, "getPivot"))
        delta = vectorSubtract(nextPivot, currentPivot)
      end
      -- A child's animation position moves its pivot in the parent frame.
      local childPosition = readAnimatedPosition(runtime.linkNodes[index + 1])
      delta = vectorAdd(delta, childPosition)
    else
      delta = runtime.terminalVector or vector(0, -1, 0)
    end
    if vectorLength(delta) < 0.001 then delta = vector(0, -math.max(runtime.restLengths[index] or 1, 0.1), 0) end
    local animatedDelta = transformVector(animatedFrame, delta)
    local point = points[index + 1] or vector(0, 0, 0)
    point.x, point.y, point.z = points[index].x + animatedDelta.x,
      points[index].y + animatedDelta.y, points[index].z + animatedDelta.z
    points[index + 1] = point

    local applied = runtime.appliedEuler[index] or vector(0, 0, 0)
    rotationMatrixInto(applied, rotationScratch)
    multiplyMatrixInto(poseFrameScratch, poseFrame, rotationScratch)
    poseFrame, poseFrameScratch = poseFrameScratch, poseFrame
  end
  for index = count + 2, #points do points[index] = nil end
  runtime.animatedFrame, runtime.animatedFrameScratch = animatedFrame, animatedFrameScratch
  runtime.poseFrame, runtime.poseFrameScratch = poseFrame, poseFrameScratch
  runtime.rotationScratch = rotationScratch
  return points
end

local function worldToChainGravityFrame(runtime)
  local root = runtime.linkNodes[1] and runtime.linkNodes[1].part
  local parent = safeCall(root, "getParent")
  local worldMatrix = safeCall(parent, "partToWorldMatrix")
  local inverse = safeCall(worldMatrix, "inverted")
  if not inverse or type(vec) ~= "function" then return nil end

  local function transformedAxis(x, y, z)
    local ok, result = pcall(function() return inverse:applyDir(vec(x, y, z)) end)
    if not ok or not result then return nil end
    return vectorFrom(result)
  end

  local xAxis = transformedAxis(1, 0, 0)
  local yAxis = transformedAxis(0, 1, 0)
  local zAxis = transformedAxis(0, 0, 1)
  if not xAxis or not yAxis or not zAxis then return nil end
  return {
    { xAxis.x, yAxis.x, zAxis.x },
    { xAxis.y, yAxis.y, zAxis.y },
    { xAxis.z, yAxis.z, zAxis.z },
  }
end

function physicsStudio.postRender()
  if not physicsStudio.initialized then return end
  for _, runtime in ipairs(physicsStudio.runtimeChains or {}) do
    if runtime.enabled and runtime.settings.gravitySpace == "world" then
      local frame = worldToChainGravityFrame(runtime)
      if frame then
        runtime.gravityFrame = frame
        runtime.gravityFrameAvailable = true
        runtime.settings.gravityFrame = frame
      end
    end
  end
end

local function clearOffsets()
  for _, runtime in ipairs(physicsStudio.runtimeChains or {}) do
    for index, node in ipairs(runtime.linkNodes or {}) do
      local part = node.part
      if part and type(part.setOffsetRot) == "function" then
        pcall(part.setOffsetRot, part, 0, 0, 0)
      end
      runtime.appliedEuler[index] = vector(0, 0, 0)
    end
  end
  physicsGizmos.clear(physicsStudio.gizmos)
end

local function getModelRoot()
  local ok, modelCollection = pcall(function() return models end)
  if not ok or not modelCollection then return nil end
  local modelParts = safeCall(modelCollection, "getChildren")
  if type(modelParts) ~= "table" then return nil end

  local function sortedChildren(parent)
    local raw = safeCall(parent, "getChildren")
    local result = {}
    if type(raw) == "table" then
      for _, child in pairs(raw) do if child then result[#result + 1] = child end end
    end
    table.sort(result, function(a, b)
      return tostring(safeCall(a, "getName") or "") < tostring(safeCall(b, "getName") or "")
    end)
    return result
  end

  local candidates = {}
  for _, modelPart in ipairs(sortedChildren(modelCollection)) do
    local modelName = safeCall(modelPart, "getName")
    if modelName ~= "PhysicsStudioHUD" and modelName ~= "PhysicsStudioGizmos" then
      local children = sortedChildren(modelPart)
      for _, child in ipairs(children) do
        if safeCall(child, "getName") == "root" and safeCall(child, "getType") == "GROUP" then
          return child
        end
      end
      if safeCall(modelPart, "getType") == "GROUP" then candidates[#candidates + 1] = modelPart end
    end
  end
  if candidates[1] then return candidates[1] end
  return nil
end

local function makeRuntime(configChain, index, usedLinks, oldStates)
  local rootKey = keyForPath(configChain.rootPath)
  local discovered, discoverError = physicsChain.discover(physicsStudio.registry, rootKey, configChain.branchChoices)
  if not discovered then return nil, "chain " .. index .. ": " .. tostring(discoverError) end
  if not discovered.complete then return nil, "chain " .. index .. " has an unresolved or invalid branch" end
  local linkKeys, linkNodes = {}, {}
  for linkIndex, path in ipairs(configChain.linkPaths or {}) do
    local key = keyForPath(path)
    if key ~= discovered.linkKeys[linkIndex] then
      return nil, "chain " .. index .. " no longer matches the discovered hierarchy at link " .. linkIndex
    end
    local node = physicsStudio.registry.byKey[key]
    if not node or node.partType ~= "GROUP" then
      return nil, "chain " .. index .. " has a missing/non-GROUP link: " .. key
    end
    if usedLinks[key] then return nil, "chain " .. index .. " overlaps another chain" end
    usedLinks[key] = true
    linkKeys[#linkKeys + 1] = key
    linkNodes[#linkNodes + 1] = node
  end
  if #linkKeys ~= #discovered.linkKeys then return nil, "chain " .. index .. " has an incomplete saved link list" end

  local restLengths = {}
  for linkIndex = 1, #linkKeys - 1 do
    restLengths[linkIndex] = discovered.restLengths[linkIndex]
  end
  local terminalLength = restLengths[#linkKeys - 1] or 1
  restLengths[#linkKeys] = math.max(0.1, terminalLength)
  local lastDelta = #linkKeys > 1 and vectorSubtract(
    vectorFrom(safeCall(linkNodes[#linkKeys].part, "getPivot")),
    vectorFrom(safeCall(linkNodes[#linkKeys - 1].part, "getPivot"))) or vector(0, -1, 0)
  local lastLength = vectorLength(lastDelta)
  if lastLength < 0.001 then lastDelta = vector(0, -1, 0); lastLength = 1 end
  local terminalVector = vector(lastDelta.x / lastLength * restLengths[#linkKeys],
    lastDelta.y / lastLength * restLengths[#linkKeys], lastDelta.z / lastLength * restLengths[#linkKeys])
  local pivotDeltas = {}
  for linkIndex = 1, #linkKeys - 1 do
    local currentPivot = vectorFrom(safeCall(linkNodes[linkIndex].part, "getPivot"))
    local nextPivot = vectorFrom(safeCall(linkNodes[linkIndex + 1].part, "getPivot"))
    pivotDeltas[linkIndex] = vectorSubtract(nextPivot, currentPivot)
  end

  local keySignature = linksSignature(linkKeys)
  local old = oldStates[rootKey]
  local runtimeSettings = {}
  for key, value in pairs(configChain.settings or {}) do runtimeSettings[key] = value end
  runtimeSettings.linkOverrides = configChain.linkOverrides or {}
  local state
  if configChain.enabled == true and old and sameKeys(old.linkKeys, linkKeys) then
    state = old.state
  else
    local base = buildAnimatedBase({ linkNodes = linkNodes, appliedEuler = {}, restLengths = restLengths,
      terminalVector = terminalVector, pivotDeltas = pivotDeltas })
    state = physicsCore.newChainState(linkKeys, base)
  end
  local resolvedLinks = physicsCore.resolveLinks(runtimeSettings, #linkKeys)
  local runtime = {
    key = rootKey,
    rootNode = physicsStudio.registry.byKey[rootKey],
    linkKeys = linkKeys,
    linkNodes = linkNodes,
    linkPaths = configChain.linkPaths,
    restLengths = restLengths,
    terminalVector = terminalVector,
    pivotDeltas = pivotDeltas,
    settings = runtimeSettings,
    gravityFrame = identity(),
    gravityFrameAvailable = false,
    resolvedLinks = resolvedLinks,
    enabled = configChain.enabled == true,
    config = configChain,
    state = state,
    appliedEuler = {},
    parentFrames = {},
    runtimeError = nil,
  }
  runtime.settings.gravityFrame = runtime.gravityFrame
  for linkIndex = 1, #linkKeys do runtime.appliedEuler[linkIndex] = vector(0, 0, 0) end
  buildAnimatedBase(runtime)
  runtime.chainStateSignature = keySignature
  return runtime
end

function physicsStudio.rebuildRuntime()
  local oldStates = {}
  for _, runtime in ipairs(physicsStudio.runtimeChains) do
    oldStates[runtime.key] = { linkKeys = runtime.linkKeys, state = runtime.state }
  end
  clearOffsets()
  physicsStudio.runtimeChains = {}
  if not physicsStudio.registry or not physicsStudio.draftConfig then return end

  local usedLinks, ownedChains, runtimeWarnings = {}, {}, {}
  for index, configChain in ipairs(physicsStudio.draftConfig.chains or {}) do
    local conflictPath = physicsChain.findOverlap(ownedChains, configChain)
    if conflictPath then
      runtimeWarnings[#runtimeWarnings + 1] = "Цепь " .. index .. ": пересекается с другой"
    else
      local runtime, err = makeRuntime(configChain, index, usedLinks, oldStates)
      if runtime then
        physicsStudio.runtimeChains[#physicsStudio.runtimeChains + 1] = runtime
        ownedChains[#ownedChains + 1] = configChain
      else
        runtimeWarnings[#runtimeWarnings + 1] = tostring(err)
      end
    end
  end
  if #runtimeWarnings > 0 and physicsStudio.ui then
    physicsStudio.ui.status = runtimeWarnings[1]
    physicsStudio.ui:refresh()
  end
  if physicsStudio.gizmos.visible then
    local selected = physicsStudio.ui and physicsStudio.ui:currentChain()
    physicsGizmos.setVisible(physicsStudio.gizmos, physicsStudio.runtimeChains, true,
      selected and keyForPath(selected.rootPath) or nil)
  end
end

local function applyDraft(raw)
  local clean, warnings = physicsConfig.validate(raw)
  physicsStudio.draftConfig = clean
  if physicsStudio.ui then physicsStudio.ui:setDraft(clean) end
  if #warnings > 0 and physicsStudio.ui then
    physicsStudio.ui.status = warnings[1]
    physicsStudio.ui:refresh()
  end
  physicsStudio.rebuildRuntime()
end

function physicsStudio.setDraftConfig(raw)
  applyDraft(raw)
end

local function diagnosticsFor(chain)
  if not chain then return nil end
  local rootKey = keyForPath(chain.rootPath)
  local runtime
  for _, candidate in ipairs(physicsStudio.runtimeChains) do if candidate.key == rootKey then runtime = candidate break end end
  if not runtime then return { error = "цепь не активна", links = {} } end
  local movement = physicsStudio.lastInput or {}
  local diagnostics = {
    rootDelta = vectorFrom(movement.rootDelta),
    rootAcceleration = vectorFrom(movement.rootAcceleration),
    rootYawAcceleration = tonumber(movement.rootYawAcceleration) or 0,
    yawDelta = tonumber(movement.yawDelta) or 0,
    gravitySpace = runtime.settings.gravitySpace,
    gravityFrameAvailable = runtime.gravityFrameAvailable == true,
    links = {},
  }
  for index, node in ipairs(runtime.linkNodes) do
    local state = runtime.state and runtime.state.diagnostics and runtime.state.diagnostics[index] or {}
    local target = runtime.animatedRotations and runtime.animatedRotations[index]
      or readAnimatedRotation(runtime, index)
    local offset = runtime.state and runtime.state.offsets and runtime.state.offsets[index] or vector(0, 0, 0)
    diagnostics.links[index] = {
      name = node.name,
      angle = math.deg(tonumber(state.angle) or 0),
      speed = math.deg(tonumber(state.speed) or 0),
      airflowSpeed = tonumber(state.airflowSpeed) or 0,
      airflowAcceleration = tonumber(state.airflowAcceleration) or 0,
      avatarInertiaAcceleration = tonumber(state.avatarInertiaAcceleration) or 0,
      target = target,
      offset = vector(math.deg(offset.x), math.deg(offset.y), math.deg(offset.z)),
    }
  end
  return diagnostics
end

local function initialize()
  physicsStudio.rootPart = getModelRoot()
  if not physicsStudio.rootPart then
    if physicsStudio.initErrorKey ~= "root" then emitLog("could not find a primary GROUP ModelPart under models; retrying") end
    physicsStudio.initErrorKey = "root"
    physicsStudio.initialized = false
    return
  end
  local registry, registryError = physicsRegistry.scan(physicsStudio.rootPart)
  if not registry then
    if physicsStudio.initErrorKey ~= "registry" then emitLog("model scan failed: " .. tostring(registryError)) end
    physicsStudio.initErrorKey = "registry"
    physicsStudio.initialized = false
    return
  end
  physicsStudio.initErrorKey = nil
  physicsStudio.registry = registry
  local loadedConfig, loadWarnings = physicsConfig.load()
  physicsStudio.savedConfig = loadedConfig
  physicsStudio.draftConfig = physicsConfig.clone(physicsStudio.savedConfig)
  physicsStudio.ui = physicsUI.new(registry, physicsStudio.draftConfig, {
    onConfigChanged = function(configTable) physicsStudio.setDraftConfig(configTable) end,
    onSave = function(configTable)
      local ok, message = physicsConfig.save(configTable)
      if ok then
        physicsStudio.savedConfig = physicsConfig.validate(configTable)
        for _, chain in ipairs(physicsStudio.savedConfig.chains or {}) do chain.migrationNotice = nil end
        physicsStudio.setDraftConfig(physicsStudio.savedConfig)
        return true, message
      end
      return false, message
    end,
    onImport = function() return physicsConfig.importPortablePreset() end,
    onCancel = function()
      local restored = physicsConfig.clone(physicsStudio.savedConfig or physicsConfig.defaults())
      physicsStudio.setDraftConfig(restored)
      return restored
    end,
    getDiagnostics = diagnosticsFor,
  })
  if loadWarnings and loadWarnings[1] then physicsStudio.ui.status = loadWarnings[1] end
  physicsStudio.draftConfig = physicsStudio.ui.draft
  physicsStudio.rebuildRuntime()
  physicsStudio.initialized = true
end

function physicsStudio.tick()
  if not physicsStudio.initialized then initialize() end
  if not physicsStudio.initialized then return end
  if physicsStudio.ui then physicsStudio.ui:tick() end
  physicsStudio.tickCount = physicsStudio.tickCount + 1
  local loaded = safeCall(player, "isLoaded")
  if loaded == false then
    physicsStudio.input:reset()
    return
  end
  local wasAlive = physicsStudio.alive
  local alive = safeCall(player, "isAlive")
  physicsStudio.alive = alive ~= false
  local movement
  if physicsStudio.alive then
    if not wasAlive then
      physicsStudio.input:reset()
      physicsStudio.deathAlpha = 1
      for _, runtime in ipairs(physicsStudio.runtimeChains) do
        runtime.appliedEuler = {}
        for index = 1, #runtime.linkKeys do runtime.appliedEuler[index] = vector(0, 0, 0) end
        runtime.state = physicsCore.newChainState(runtime.linkKeys, buildAnimatedBase(runtime))
        runtime.offsets = {}
      end
    end
    local yaw = safeCall(player, "getBodyYaw")
    movement = physicsStudio.input:sample(player, yaw, DT)
  else
    if wasAlive then physicsStudio.deathAlpha = 1 end
    physicsStudio.input:reset()
    movement = { rootDelta = vector(0, 0, 0), yawDelta = 0, available = true }
    physicsStudio.deathAlpha = math.max(0, physicsStudio.deathAlpha - 0.2)
  end
  physicsStudio.lastInput = movement

  local collectDiagnostics = physicsStudio.ui ~= nil
    and physicsStudio.ui.open == true and physicsStudio.ui.diagnostics == true
  for _, runtime in ipairs(physicsStudio.runtimeChains) do
    if runtime.enabled and physicsStudio.alive then
      local base = buildAnimatedBase(runtime)
      local state, offsets, diagnostics = physicsCore.stepChain(runtime.state, movement, base,
        runtime.restLengths, runtime.settings, DT, collectDiagnostics, runtime.resolvedLinks)
      runtime.state, runtime.offsets, runtime.diagnostics = state, offsets, diagnostics
    end
  end
  if collectDiagnostics then physicsStudio.ui:refresh() end
end

function physicsStudio.render(delta)
  if not physicsStudio.initialized then return end
  delta = math.max(0, math.min(1, tonumber(delta) or 0))
  for _, runtime in ipairs(physicsStudio.runtimeChains) do
    if runtime.enabled and (physicsStudio.alive or physicsStudio.deathAlpha > 0) then
      runtime.renderOffsets = physicsCore.interpolateOffsets(runtime.state, delta, runtime.renderOffsets)
      local offsets = runtime.renderOffsets
      for index, node in ipairs(runtime.linkNodes) do
        local chainRotation = offsets[index] or vector(0, 0, 0)
        if not physicsStudio.alive then
          chainRotation.x = chainRotation.x * physicsStudio.deathAlpha
          chainRotation.y = chainRotation.y * physicsStudio.deathAlpha
          chainRotation.z = chainRotation.z * physicsStudio.deathAlpha
        end
        local frame = runtime.parentFrames[index] or identity()
        local rx, ry, rz = transformTransposeVector(frame, chainRotation)
        local x, y, z = rotationVectorToEuler(rx, ry, rz)
        local previousEuler = runtime.appliedEuler[index]
        if not previousEuler or previousEuler.x ~= x
          or previousEuler.y ~= y or previousEuler.z ~= z then
          local part = node.part
          if part and type(part.setOffsetRot) == "function" then
            pcall(part.setOffsetRot, part, x, y, z)
          end
        end
        if previousEuler then
          previousEuler.x, previousEuler.y, previousEuler.z = x, y, z
        else
          runtime.appliedEuler[index] = vector(x, y, z)
        end
      end
    else
      for index, node in ipairs(runtime.linkNodes) do
        local previousEuler = runtime.appliedEuler[index]
        if not previousEuler or previousEuler.x ~= 0 or previousEuler.y ~= 0 or previousEuler.z ~= 0 then
          runtime.appliedEuler[index] = vector(0, 0, 0)
          local part = node.part
          if part and type(part.setOffsetRot) == "function" then
            pcall(part.setOffsetRot, part, 0, 0, 0)
          end
        end
      end
    end
  end
  local gizmos = physicsStudio.gizmos
  if gizmos.visible and physicsStudio.ui and physicsStudio.ui.open then
    local selected = physicsStudio.ui:currentChain()
    local selectedRootKey = selected and keyForPath(selected.rootPath) or nil
    if gizmos.chainsRef ~= physicsStudio.runtimeChains or gizmos.selectedRootKey ~= selectedRootKey then
      physicsGizmos.setVisible(gizmos, physicsStudio.runtimeChains, true, selectedRootKey)
    end
  end
end

local editorKey = keybinds:newKeybind("Physics Studio — открыть/закрыть", "key.keyboard.f8", false)
editorKey.press = function()
  if not physicsStudio.initialized then initialize() end
  if physicsStudio.ui then physicsStudio.ui:toggle() end
end

local gizmoKey = keybinds:newKeybind("Physics Studio — gizmos (Shift + grave)", "key.keyboard.grave.accent", false)
gizmoKey.press = function(modifier)
  if modifier ~= 1 then return end
  local shouldShow = not physicsStudio.gizmos.visible
  local selected = physicsStudio.ui and physicsStudio.ui:currentChain()
  physicsGizmos.setVisible(physicsStudio.gizmos, physicsStudio.runtimeChains,
    shouldShow, selected and keyForPath(selected.rootPath) or nil)
end

local function register(eventName, callback)
  local event = events[eventName]
  if event and type(event.register) == "function" then
    event:register(callback, EVENT_NAME .. "." .. string.lower(eventName))
  else
    emitLog("event API is missing " .. eventName)
  end
end

register("ENTITY_INIT", initialize)
register("TICK", physicsStudio.tick)
register("RENDER", physicsStudio.render)
register("POST_RENDER", physicsStudio.postRender)
register("MOUSE_PRESS", function(button, action, modifier)
  if physicsStudio.ui then return physicsStudio.ui:onMousePress(button, action, modifier) end
  return false
end)
register("MOUSE_MOVE", function(dx, dy)
  if physicsStudio.ui then physicsStudio.ui:onMouseMove(dx, dy) end
  return false
end)
register("MOUSE_SCROLL", function(delta)
  if physicsStudio.ui then return physicsStudio.ui:onMouseScroll(delta) end
  return false
end)
register("CHAR_TYPED", function(character, modifier, codepoint)
  if physicsStudio.ui then return physicsStudio.ui:onCharTyped(character, modifier, codepoint) end
  return false
end)
register("KEY_PRESS", function(key, action, modifier)
  if physicsStudio.ui then return physicsStudio.ui:onKeyPress(key, action, modifier) end
  return false
end)

return physicsStudio
