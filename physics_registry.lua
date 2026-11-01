local physicsRegistry = {}

local function safeCall(part, method, ...)
  if not part then return nil end
  local fn = part[method]
  if type(fn) ~= "function" then return nil end
  local args = { ... }
  local unpackArgs = table.unpack or unpack
  local ok, value = pcall(fn, part, unpackArgs(args))
  if ok then return value end
  return nil
end

local function partName(part)
  local value = safeCall(part, "getName")
  if type(value) == "string" then return value end
  return "<unnamed>"
end

local function partType(part)
  local value = safeCall(part, "getType")
  if type(value) == "string" then return value end
  return "UNKNOWN"
end

local function finiteNumber(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function pivotComponents(part)
  local pivot = safeCall(part, "getPivot")
  if not pivot then return nil end
  local x, y, z = pivot.x, pivot.y, pivot.z
  if finiteNumber(x) and finiteNumber(y) and finiteNumber(z) then
    return x, y, z
  end
  return nil
end

local function sortedChildren(parent)
  local rawChildren = safeCall(parent, "getChildren")
  if type(rawChildren) ~= "table" then return {} end

  local children = {}
  for order, child in pairs(rawChildren) do
    if child then
      local x, y, z = pivotComponents(child)
      children[#children + 1] = {
        part = child,
        name = partName(child),
        partType = partType(child),
        x = x or 0,
        y = y or 0,
        z = z or 0,
        order = type(order) == "number" and order or #children + 1,
      }
    end
  end

  table.sort(children, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    if a.partType ~= b.partType then return a.partType < b.partType end
    if a.x ~= b.x then return a.x < b.x end
    if a.y ~= b.y then return a.y < b.y end
    if a.z ~= b.z then return a.z < b.z end
    return a.order < b.order
  end)
  return children
end

local function siblingIndex(parent, part)
  if not parent then return 1 end
  local targetName = partName(part)
  local occurrence = 0
  for _, child in ipairs(sortedChildren(parent)) do
    if child.name == targetName then
      occurrence = occurrence + 1
      if child.part == part then return occurrence end
    end
  end
  return nil
end

local function copyPath(path)
  local result = {}
  for i, segment in ipairs(path or {}) do
    if type(segment) ~= "table" or type(segment.name) ~= "string"
      or type(segment.sameNameIndex) ~= "number" or segment.sameNameIndex ~= segment.sameNameIndex
      or segment.sameNameIndex == math.huge or segment.sameNameIndex == -math.huge
      or segment.sameNameIndex < 1 then
      return nil
    end
    result[i] = {
      name = segment.name,
      sameNameIndex = math.floor(segment.sameNameIndex),
    }
  end
  if #result == 0 then return nil end
  return result
end

local function pathKey(path)
  local parts = {}
  for i, segment in ipairs(path) do
    local escapedName = segment.name:gsub("([^%w_%-])", function(char)
      return string.format("%%%02X", string.byte(char))
    end)
    parts[i] = escapedName .. "[" .. tostring(segment.sameNameIndex) .. "]"
  end
  return table.concat(parts, "/")
end

function physicsRegistry.makePath(rootPart, part)
  if not rootPart or not part then return nil, nil, "missing root or ModelPart" end
  if part ~= rootPart then
    local isChild = safeCall(part, "isChildOf", rootPart)
    if isChild ~= true then return nil, nil, "ModelPart is outside the selected model root" end
  end

  local reversed = {}
  local current = part
  while current do
    reversed[#reversed + 1] = current
    if current == rootPart then break end
    current = safeCall(current, "getParent")
  end
  if reversed[#reversed] ~= rootPart then
    return nil, nil, "could not trace ModelPart to the selected root"
  end

  local path = {}
  for i = #reversed, 1, -1 do
    local node = reversed[i]
    local parent = reversed[i + 1]
    local index = parent and siblingIndex(parent, node) or 1
    if not index then return nil, nil, "could not identify ModelPart among its siblings" end
    path[#path + 1] = { name = partName(node), sameNameIndex = index }
  end
  return path, pathKey(path)
end

function physicsRegistry.resolve(rootPart, path)
  local cleanPath = copyPath(path)
  if not rootPart or not cleanPath then return nil, "invalid root or ModelPart path" end

  local rootSegment = cleanPath[1]
  if rootSegment.name ~= partName(rootPart) or rootSegment.sameNameIndex ~= 1 then
    return nil, "path root no longer matches this model"
  end

  local current = rootPart
  for pathIndex = 2, #cleanPath do
    local segment = cleanPath[pathIndex]
    local occurrence = 0
    local found = nil
    for _, child in ipairs(sortedChildren(current)) do
      if child.name == segment.name then
        occurrence = occurrence + 1
        if occurrence == segment.sameNameIndex then
          found = child.part
          break
        end
      end
    end
    if not found then return nil, "ModelPart path segment is missing: " .. segment.name end
    current = found
  end
  return current
end

function physicsRegistry.scan(rootPart)
  if not rootPart then return nil, "model root is unavailable" end
  local result = { root = rootPart, roots = {}, flat = {}, byKey = {} }

  local function visit(part, path, parentKey, depth)
    local key = pathKey(path)
    local node = {
      key = key,
      name = partName(part),
      partType = partType(part),
      part = part,
      path = copyPath(path),
      parentKey = parentKey,
      children = {},
      depth = depth,
    }
    result.flat[#result.flat + 1] = node
    result.byKey[key] = node
    if parentKey then
      local parentNode = result.byKey[parentKey]
      if parentNode then parentNode.children[#parentNode.children + 1] = node end
    else
      result.roots[#result.roots + 1] = node
    end

    local sameNameCounts = {}
    for _, child in ipairs(sortedChildren(part)) do
      local occurrence = (sameNameCounts[child.name] or 0) + 1
      sameNameCounts[child.name] = occurrence
      local childPath = copyPath(path)
      childPath[#childPath + 1] = {
        name = child.name,
        sameNameIndex = occurrence,
      }
      visit(child.part, childPath, key, depth + 1)
    end
  end

  visit(rootPart, { { name = partName(rootPart), sameNameIndex = 1 } }, nil, 0)
  return result
end

local function vectorFromPivots(fromPart, toPart)
  local fromPivot = safeCall(fromPart, "getPivot")
  local toPivot = safeCall(toPart, "getPivot")
  if not fromPivot or not toPivot then return nil, "could not read endpoint pivots" end
  local ok, delta = pcall(function() return toPivot - fromPivot end)
  if not ok or not delta then return nil, "could not calculate endpoint vector" end
  local vector = { x = delta.x, y = delta.y, z = delta.z }
  if not finiteNumber(vector.x) or not finiteNumber(vector.y) or not finiteNumber(vector.z) then
    return nil, "endpoint vector contains an invalid number"
  end
  local length = math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
  if length < 0.001 then return nil, "endpoint is too close to the selected pivot" end
  return vector
end

function physicsRegistry.getEndpoint(node, endpointConfig, registry)
  if not node or not node.part or type(endpointConfig) ~= "table" then
    return nil, "target or endpoint settings are missing"
  end

  if endpointConfig.mode == "manual" then
    local vector = endpointConfig.vector
    if type(vector) ~= "table" or not finiteNumber(vector.x)
      or not finiteNumber(vector.y) or not finiteNumber(vector.z) then
      return nil, "manual endpoint must contain finite x/y/z values"
    end
    local length = math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
    if length < 0.001 then return nil, "manual endpoint is too close to the pivot" end
    return { x = vector.x, y = vector.y, z = vector.z }
  end

  if endpointConfig.mode == "child" then
    local childPath = copyPath(endpointConfig.childPath)
    if not childPath then return nil, "child endpoint path is invalid" end
    if #childPath <= #(node.path or {}) then return nil, "child endpoint must be below the selected ModelPart" end
    for i, segment in ipairs(node.path or {}) do
      if childPath[i].name ~= segment.name or childPath[i].sameNameIndex ~= segment.sameNameIndex then
        return nil, "child endpoint must be below the selected ModelPart"
      end
    end
    local child, err = physicsRegistry.resolve(registry and registry.root, childPath)
    if not child then return nil, err or "endpoint child is unavailable" end
    return vectorFromPivots(node.part, child)
  end

  if endpointConfig.mode == "marker" then
    for _, child in ipairs(sortedChildren(node.part)) do
      if child.name == "phys_end" then return vectorFromPivots(node.part, child.part) end
    end
    return nil, "no direct child named phys_end exists"
  end

  return nil, "unsupported endpoint mode"
end

return physicsRegistry
