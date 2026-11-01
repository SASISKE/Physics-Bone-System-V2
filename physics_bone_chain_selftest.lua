-- Deterministic graph tests for branch selection and component overlap.
local registryApi = require("physics_bone_registry")
local chainApi = require("physics_bone_chain")

local tests = {}

local function expect(name, callback)
  local ok, result = pcall(callback)
  tests[#tests + 1] = {
    name = name,
    passed = ok and result == true,
    error = not ok and tostring(result) or (type(result) == "string" and result or nil),
  }
end

local function path(parent, name, sameNameIndex)
  local result = {}
  for index, segment in ipairs(parent or {}) do
    result[index] = { name = segment.name, sameNameIndex = segment.sameNameIndex }
  end
  result[#result + 1] = { name = name, sameNameIndex = sameNameIndex or 1 }
  return result
end

local function fixture()
  local rootPath = { { name = "root", sameNameIndex = 1 } }
  local leftPath = path(rootPath, "left")
  local rightPath = path(rootPath, "right")
  local root = { name = "root", partType = "GROUP", transformable = true, path = rootPath,
    key = registryApi.pathKey(rootPath), pivot = { x = 0, y = 0, z = 0 }, children = {} }
  local left = { name = "left", partType = "GROUP", transformable = true, path = leftPath,
    key = registryApi.pathKey(leftPath), pivot = { x = -1, y = 1, z = 0 }, children = {} }
  local right = { name = "right", partType = "GROUP", transformable = true, path = rightPath,
    key = registryApi.pathKey(rightPath), pivot = { x = 1, y = 1, z = 0 }, children = {} }
  root.children = { left, right }
  local registry = { flat = { root, left, right }, byKey = {
    [root.key] = root, [left.key] = left, [right.key] = right,
  } }
  local endpoint = { mode = "manual", vector = { x = 0, y = 1, z = 0 } }
  return registry, root, left, right, endpoint
end

function tests.run()
  expect("unresolved branch requires an explicit choice", function()
    local registry, root, _, _, endpoint = fixture()
    local graph = chainApi.build(registry, { rootPath = root.path, endpoint = endpoint })
    return graph and graph.complete == false and #graph.branches == 1
      and #graph.branches[1].candidates == 2
  end)

  expect("selected branch builds one continuous component", function()
    local registry, root, left, _, endpoint = fixture()
    local graph = chainApi.build(registry, {
      rootPath = root.path, branchMode = "selected", branchChoices = { [root.key] = left.key }, endpoint = endpoint,
    })
    return graph and graph.complete == true and #graph.links == 2 and #graph.edges == 2
      and #graph.attachments == 1 and graph.attachments[1].key ~= left.key
  end)

  expect("all branches build without duplicate links", function()
    local registry, root, _, _, endpoint = fixture()
    local graph = chainApi.build(registry, { rootPath = root.path, branchMode = "all", endpoint = endpoint })
    if not graph or graph.complete ~= true or #graph.links ~= 3 or #graph.edges ~= 4 then return false end
    local keys = {}
    for _, link in ipairs(graph.links) do
      if keys[link.key] then return false end
      keys[link.key] = true
    end
    return true
  end)

  expect("excluded branch remains an attachment", function()
    local registry, root, left, _, endpoint = fixture()
    local graph = chainApi.build(registry, {
      rootPath = root.path, branchMode = "all", excludedPaths = { left.path }, endpoint = endpoint,
    })
    return graph and graph.complete == true and #graph.links == 2 and #graph.attachments == 1
      and graph.attachments[1].excluded == true and graph.attachments[1].key == left.key
  end)

  expect("overlapping components are rejected while sibling roots remain separate", function()
    local registry, root, left, right, endpoint = fixture()
    local whole = chainApi.build(registry, { rootPath = root.path, branchMode = "all", endpoint = endpoint })
    local leftGraph = chainApi.build(registry, { rootPath = left.path, endpoint = endpoint })
    local rightGraph = chainApi.build(registry, { rootPath = right.path, endpoint = endpoint })
    local overlap = chainApi.findOverlap({ whole }, leftGraph)
    local siblingOverlap = chainApi.findOverlap({ leftGraph }, rightGraph)
    return whole and leftGraph and rightGraph and overlap ~= nil and siblingOverlap == nil
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
