local physicsGizmos = {}

local function safeCall(object, method, ...)
  if not object then return nil end
  local fn = object[method]
  if type(fn) ~= "function" then return nil end
  local args = { ... }
  local ok, value = pcall(fn, object, (table.unpack or unpack)(args))
  if ok then return value end
  return nil
end

local function vectorFromPivot(node, nextNode)
  local from = safeCall(node and node.part, "getPivot")
  local to = safeCall(nextNode and nextNode.part, "getPivot")
  if not from or not to then return { x = 0, y = -1, z = 0 }, 1 end
  local delta = { x = to.x - from.x, y = to.y - from.y, z = to.z - from.z }
  local length = math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
  if length < 0.001 then return { x = 0, y = -1, z = 0 }, 1 end
  return delta, length
end

local function vectorToEuler(direction)
  local from = { x = 0, y = 1, z = 0 }
  local toLength = math.sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
  if toLength < 0.001 then return 0, 0, 0 end
  local to = { x = direction.x / toLength, y = direction.y / toLength, z = direction.z / toLength }
  local axis = {
    x = from.y * to.z - from.z * to.y,
    y = from.z * to.x - from.x * to.z,
    z = from.x * to.y - from.y * to.x,
  }
  local axisLength = math.sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
  local dot = math.max(-1, math.min(1, from.x * to.x + from.y * to.y + from.z * to.z))
  local angle = math.acos(dot)
  if axisLength < 0.001 then return dot < 0 and 180 or 0, 0, 0 end
  axis.x, axis.y, axis.z = axis.x / axisLength, axis.y / axisLength, axis.z / axisLength
  local s, c, t = math.sin(angle), math.cos(angle), 1 - math.cos(angle)
  local r11 = t * axis.x * axis.x + c
  local r21 = t * axis.x * axis.y + s * axis.z
  local r31 = t * axis.x * axis.z - s * axis.y
  local r32 = t * axis.y * axis.z + s * axis.x
  local r33 = t * axis.z * axis.z + c
  local y = math.asin(math.max(-1, math.min(1, -r31)))
  local function atan2(yValue, xValue)
    if math.atan2 then return math.atan2(yValue, xValue) end
    if xValue > 0 then return math.atan(yValue / xValue) end
    if xValue < 0 and yValue >= 0 then return math.atan(yValue / xValue) + math.pi end
    if xValue < 0 and yValue < 0 then return math.atan(yValue / xValue) - math.pi end
    if xValue == 0 and yValue > 0 then return math.pi / 2 end
    if xValue == 0 and yValue < 0 then return -math.pi / 2 end
    return 0
  end
  local x = atan2(r32, r33)
  local z = atan2(r21, r11)
  return math.deg(x), math.deg(y), math.deg(z)
end

local function createTexture()
  local ok, texture = pcall(function() return textures:newTexture("PhysBoneV2GizmoWhite", 1, 1) end)
  if not ok or not texture then return nil end
  safeCall(texture, "setPixel", 0, 0, vec(1, 1, 1, 1))
  safeCall(texture, "update")
  return texture
end

local function addBeam(parent, texture, name, color, length, direction)
  local group = safeCall(parent, "newPart", name)
  if not group then return nil end
  local pitch, yaw, roll = vectorToEuler(direction)
  safeCall(group, "setRot", pitch, yaw, roll)
  safeCall(group, "setScale", 1, math.max(0.05, length), 1)
  for index = 1, 4 do
    local sprite = safeCall(group, "newSprite", name .. "Face" .. index)
    if sprite then
      safeCall(sprite, "setTexture", texture, 1, 1)
      safeCall(sprite, "setColor", color[1], color[2], color[3])
      safeCall(sprite, "setRenderType", "EMISSIVE_SOLID")
      local angle = (index - 1) * 90
      local matrix = matrices.mat4():translate(0.5, 0, 0.5):scale(0.10, 1, 0.10):rotate(0, angle, 0) * 0.12
      safeCall(sprite, "setMatrix", matrix)
    end
  end
  return group
end

local function addMarker(parent, texture, name, color)
  local marker = safeCall(parent, "newPart", name, "Camera")
  local sprite = marker and safeCall(marker, "newSprite", name .. "Sprite")
  if not sprite then return marker end
  safeCall(sprite, "setTexture", texture, 1, 1)
  safeCall(sprite, "setColor", color[1], color[2], color[3])
  safeCall(sprite, "setRenderType", "EMISSIVE_SOLID")
  safeCall(sprite, "setMatrix", matrices.mat4():translate(0.5, 0.5, 0.5):scale(0.16, 0.16, 0.16) * 0.1)
  return marker
end

function physicsGizmos.new()
  return {
    visible = false,
    roots = {},
    entries = {},
    texture = nil,
    chainsRef = nil,
    selectedRootKey = nil,
  }
end

function physicsGizmos.clear(manager)
  if not manager then return end
  for _, root in ipairs(manager.roots or {}) do safeCall(root, "remove") end
  manager.roots, manager.entries = {}, {}
  manager.chainsRef, manager.selectedRootKey = nil, nil
end

function physicsGizmos.setVisible(manager, chains, visible, selectedRootKey)
  if not manager then return end
  local shouldShow = visible == true
  if not shouldShow then
    manager.visible = false
    for _, root in ipairs(manager.roots or {}) do safeCall(root, "setVisible", false) end
    return
  end
  local wasVisible = manager.visible == true
  manager.visible = true
  if manager.chainsRef == chains and manager.selectedRootKey == selectedRootKey then
    if not wasVisible then
      for _, entry in ipairs(manager.entries or {}) do
        local selected = entry.chainKey == selectedRootKey
        if entry.root then
          safeCall(entry.root, "setVisible", true)
          safeCall(entry.root, "setColor", selected and 0.2 or 0.15, selected and 1 or 0.65, selected and 0.35 or 1)
        end
      end
    end
    return
  end
  physicsGizmos.clear(manager)
  manager.visible = true
  manager.chainsRef = chains
  manager.selectedRootKey = selectedRootKey
  manager.texture = manager.texture or createTexture()
  if not manager.texture then return end
  for _, component in ipairs(chains or {}) do
    local color = component.key == selectedRootKey and { 0.2, 1, 0.35 } or { 0.15, 0.65, 1 }
    local graph = component.graph or {}
    for index, node in ipairs(component.linkNodes or {}) do
      local marker = addMarker(node.part, manager.texture, "PhysBoneV2Joint_" .. index, color)
      if marker then
        manager.roots[#manager.roots + 1] = marker
        manager.entries[#manager.entries + 1] = { root = marker, chainKey = component.key, index = index, kind = "joint" }
      end
      for edgeIndex, edge in ipairs((graph.edgesByLink and graph.edgesByLink[index]) or {}) do
          local direction = edge.restVector or { x = 0, y = -1, z = 0 }
          local beam = addBeam(node.part, manager.texture, "PhysBoneV2Link_" .. index .. "_" .. edgeIndex,
            color, edge.restLength or 1, direction)
          if beam then
            manager.roots[#manager.roots + 1] = beam
            manager.entries[#manager.entries + 1] = { root = beam, chainKey = component.key, index = index, kind = "link" }
          end
          if edge.terminal then
            local endpoint = addMarker(node.part, manager.texture, "PhysBoneV2Tip_" .. index, { 1, 0.35, 0.15 })
            if endpoint then
              safeCall(endpoint, "setPos", direction.x, direction.y, direction.z)
              manager.roots[#manager.roots + 1] = endpoint
              manager.entries[#manager.entries + 1] = { root = endpoint, chainKey = component.key, index = index, kind = "endpoint" }
            end
          end
      end
    end
  end
  for _, entry in ipairs(manager.entries or {}) do
    local selected = entry.chainKey == selectedRootKey
    if entry.root then
      safeCall(entry.root, "setVisible", true)
      safeCall(entry.root, "setColor", selected and 0.2 or 0.15, selected and 1 or 0.65, selected and 0.35 or 1)
    end
  end
end

return physicsGizmos

