local physicsChain = {}

local function copyPath(path)
  local copy = {}
  for index, segment in ipairs(path or {}) do
    copy[index] = { name = segment.name, sameNameIndex = segment.sameNameIndex }
  end
  return copy
end

local function pathKey(path)
  local parts = {}
  for index, segment in ipairs(path or {}) do
    local name = tostring(segment.name):gsub("([^%w_%-])", function(char)
      return string.format("%%%02X", string.byte(char))
    end)
    parts[index] = name .. "[" .. tostring(segment.sameNameIndex) .. "]"
  end
  return table.concat(parts, "/")
end

local function safeCall(object, method)
  if not object then return nil end
  local fn = object[method]
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, object)
  if ok then return value end
  return nil
end

local function isGroup(node)
  return node and node.partType == "GROUP"
end

local function groupChildren(node)
  local children = {}
  for _, child in ipairs(node and node.children or {}) do
    if isGroup(child) then children[#children + 1] = child end
  end
  table.sort(children, function(a, b) return a.key < b.key end)
  return children
end

local function hasGroupDescendant(node, visited)
  visited = visited or {}
  if not node or visited[node.key] then return false end
  visited[node.key] = true
  for _, child in ipairs(groupChildren(node)) do
    return true
  end
  return false
end

local function pivotDistance(fromNode, toNode)
  local fromPivot = safeCall(fromNode and fromNode.part, "getPivot")
  local toPivot = safeCall(toNode and toNode.part, "getPivot")
  if not fromPivot or not toPivot then return nil end
  local dx, dy, dz = toPivot.x - fromPivot.x, toPivot.y - fromPivot.y, toPivot.z - fromPivot.z
  local length = math.sqrt(dx * dx + dy * dy + dz * dz)
  if length ~= length or length == math.huge or length < 0.001 then return nil end
  return length
end

local function addAttachment(result, parent, child)
  result.attachments[#result.attachments + 1] = {
    key = child.key,
    path = copyPath(child.path),
    parentKey = parent.key,
    name = child.name,
  }
end

function physicsChain.discover(registry, rootKey, branchChoices)
  if type(registry) ~= "table" or type(registry.byKey) ~= "table" then
    return nil, "model registry is unavailable"
  end
  local root = registry.byKey[rootKey]
  if not root then return nil, "chain root is missing from the model registry" end
  if not isGroup(root) then return nil, "only GROUP ModelParts can be chain roots" end

  local result = {
    rootKey = root.key,
    rootPath = copyPath(root.path),
    linkKeys = {},
    linkPaths = {},
    restLengths = {},
    attachments = {},
    unresolvedBranches = {},
    complete = true,
  }
  local current = root
  local seen = {}
  local maxDepth = math.min(#(registry.flat or {}) + 1, 256)

  for _ = 1, maxDepth do
    if seen[current.key] then return nil, "cycle detected in ModelPart hierarchy" end
    seen[current.key] = true
    result.linkKeys[#result.linkKeys + 1] = current.key
    result.linkPaths[#result.linkPaths + 1] = copyPath(current.path)

    local children = groupChildren(current)
    if #children == 0 then break end

    local nextNode
    if #children == 1 then
      nextNode = children[1]
    else
      local candidates = {}
      for _, child in ipairs(children) do
        if hasGroupDescendant(child) then candidates[#candidates + 1] = child end
      end

      local chosenKey = type(branchChoices) == "table" and branchChoices[current.key] or nil
      if chosenKey then
        for _, child in ipairs(children) do
          if child.key == chosenKey then nextNode = child break end
        end
        if not nextNode then
          return nil, "saved branch choice is no longer a child of " .. current.name
        end
      elseif #candidates == 1 then
        nextNode = candidates[1]
      elseif #candidates > 1 then
        local branch = { parentKey = current.key, parentPath = copyPath(current.path), candidates = {} }
        for _, candidate in ipairs(candidates) do
          branch.candidates[#branch.candidates + 1] = {
            key = candidate.key, name = candidate.name, path = copyPath(candidate.path),
          }
        end
        result.unresolvedBranches[#result.unresolvedBranches + 1] = branch
        result.complete = false
      end

      for _, child in ipairs(children) do
        if child ~= nextNode then addAttachment(result, current, child) end
      end
      if not nextNode then break end
    end

    current = nextNode
  end

  if #result.linkKeys >= maxDepth then
    return nil, "chain exceeds the safe depth limit"
  end
  for index = 1, #result.linkKeys - 1 do
    local fromNode = registry.byKey[result.linkKeys[index]]
    local toNode = registry.byKey[result.linkKeys[index + 1]]
    local length = pivotDistance(fromNode, toNode)
    if not length then
      result.complete = false
      result.restLengths[index] = 0
    else
      result.restLengths[index] = length
    end
  end
  return result
end

local function isPrefix(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or #a > #b then return false end
  for index, segment in ipairs(a) do
    local other = b[index]
    if not other or segment.name ~= other.name or segment.sameNameIndex ~= other.sameNameIndex then
      return false
    end
  end
  return true
end

function physicsChain.findOverlap(chains, candidate)
  local candidateLinks = {}
  for _, path in ipairs(candidate and candidate.linkPaths or {}) do
    candidateLinks[pathKey(path)] = true
  end
  for _, existing in ipairs(chains or {}) do
    local existingPath = existing.rootPath
    local candidateRoot = candidate and candidate.rootPath
    local rootOverlap = existingPath and candidateRoot
      and (isPrefix(existingPath, candidateRoot) or isPrefix(candidateRoot, existingPath))
    for _, path in ipairs(existing.linkPaths or {}) do
      if candidateLinks[pathKey(path)] then return existing.rootPath, "shared link" end
    end
    if rootOverlap then return existing.rootPath, "overlapping roots" end
  end
  return nil
end

function physicsChain.pathKey(path)
  return pathKey(path)
end

return physicsChain
