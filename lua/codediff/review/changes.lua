local M = {}

-- Excerpts own changed blocks. Files listed without excerpts own all their blocks.
function M.build(snapshot, step)
  local blocks, used = {}, {}
  local function add(file_id, change_id)
    local key = file_id .. ":" .. change_id
    if used[key] then
      return
    end
    used[key] = true
    blocks[#blocks + 1] = { file_id = file_id, change_id = change_id, file = snapshot.files[file_id], change = snapshot.files[file_id].changes[change_id] }
  end
  for _, excerpt in ipairs(step.excerpts) do
    add(excerpt.file_id, excerpt.change_id)
  end
  for _, id in ipairs(step.files) do
    local file = snapshot.files[id]
    if #file.changes == 0 then
      blocks[#blocks + 1] = { file_id = id, file = file }
    else
      for change_id in ipairs(file.changes) do
        add(id, change_id)
      end
    end
  end
  local result = { original = {}, modified = {}, locations = { original = {}, modified = {} }, blocks = blocks }
  local function append(side, value, location)
    table.insert(result[side], value)
    result.locations[side][#result[side]] = location or false
  end
  for _, block in ipairs(blocks) do
    local file, change = block.file, block.change
    local label = string.format(
      "── %s%s%s ──",
      file.file,
      file.group and " [" .. file.group .. "]" or "",
      block.change_id and " · change " .. block.change_id or " · no text changes"
    )
    block.rows = {}
    local before, after = 0, 0
    if change then
      local old, new = change.original, change.modified
      local old_before = old.start_line - old.context_start_line
      local new_before = new.start_line - new.context_start_line
      for count = 1, math.min(3, old_before, new_before) do
        if old.context[old_before - count + 1] ~= new.context[new_before - count + 1] then
          break
        end
        before = count
      end
      local old_after = old.end_line - old.context_start_line + 1
      local new_after = new.end_line - new.context_start_line + 1
      for count = 0, 2 do
        if not old.context[old_after + count] or old.context[old_after + count] ~= new.context[new_after + count] then
          break
        end
        after = count + 1
      end
    end
    for _, side in ipairs({ "original", "modified" }) do
      append(side, label)
      if change then
        local range = change[side]
        for line = range.start_line - before, range.end_line - 1 + after do
          local value = line >= range.start_line and line < range.end_line and range.lines[line - range.start_line + 1] or range.context[line - range.context_start_line + 1]
          append(side, value, { path = file.file, group = file.group, line = line, file_id = block.file_id, change_id = block.change_id })
        end
      end
      block.rows[side] = #result[side] - (change and #change[side].lines + after or 0) + 1
      append(side, "")
    end
  end
  if #blocks == 0 then
    result.original, result.modified = { "This stop has no code changes." }, { "This stop has no code changes." }
  end
  return result
end

return M
