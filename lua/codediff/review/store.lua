local M = {}

local function path(key)
  return vim.fn.stdpath("cache") .. "/codediff-review/" .. key .. ".json"
end

function M.read(snapshot)
  local ok, value = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path(snapshot.key)), "\n"))
  end)
  if not ok or type(value) ~= "table" or value.version ~= 1 or type(value.steps) ~= "table" then
    return nil
  end
  -- Cached guides have the same validation boundary as provider responses.
  local steps = require("codediff.review.format").decode(vim.json.encode({ steps = value.steps }), snapshot)
  if not steps then
    return nil
  end
  local position = type(value.position) == "number" and math.floor(value.position) or 1
  local seen = {}
  for id, marked in pairs(type(value.seen) == "table" and value.seen or {}) do
    local index = tonumber(id)
    if index and steps[index] and marked == true then
      seen[index] = true
    end
  end
  return { steps = steps, position = math.max(1, math.min(#steps, position)), seen = seen }
end

function M.write(state)
  if not state.snapshot or not state.steps then
    return
  end
  local seen = vim.empty_dict()
  for index, marked in pairs(state.seen) do
    seen[tostring(index)] = marked
  end
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fn.stdpath("cache") .. "/codediff-review", "p")
    local filename = path(state.snapshot.key)
    local temporary = filename .. "." .. vim.fn.getpid() .. ".tmp"
    local written = vim.fn.writefile({ vim.json.encode({ version = 1, steps = state.steps, position = state.position, seen = seen }) }, temporary)
    if written ~= 0 then
      error("Could not write review progress")
    end
    local renamed, failure = (vim.uv or vim.loop).fs_rename(temporary, filename)
    if not renamed then
      error(failure)
    end
  end)
  if not ok then
    vim.notify("CodeDiff review: Could not save progress: " .. tostring(err), vim.log.levels.WARN)
  end
end

return M
