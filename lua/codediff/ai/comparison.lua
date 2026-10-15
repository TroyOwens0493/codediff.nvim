-- Context from the complete comparison, including files outside the selected pane.
local M = {}
local context = require("codediff.ai.context")
local inputs = require("codediff.ui.refresh.inputs")
local panels = require("codediff.ui.refresh.panel")

local function entries_for(session)
  local entries = {}
  local panel = session.panel
  if not panel then
    return entries
  end
  local data = panel.data
  if panel.name == "explorer" then
    local visible = panel.view and panel.view.visible_groups or require("codediff.config").options.explorer.visible_groups
    for _, group in ipairs({ "unstaged", "staged" }) do
      if data.base_revision or not data.git_root or visible[group] ~= false then
        local files = require("codediff.ui.explorer.filter").apply((data.status_result or {})[group] or {}, require("codediff.config").options.explorer.file_filter.ignore or {})
        files = require("codediff.ui.explorer.nodes").filter_merge_artifacts(files)
        for _, file in ipairs(files) do
          entries[#entries + 1] = vim.tbl_extend("force", file, { group = group })
        end
      end
    end
  elseif panel.name == "history" then
    for _, file in ipairs(data.files[data.current_commit] or {}) do
      entries[#entries + 1] = vim.tbl_extend("force", file, { commit_hash = data.current_commit })
    end
  end
  return entries
end

-- Reads run asynchronously. Cancellation prevents subsequent reads and delivery.
function M.capture(session, snapshot, opts, done)
  local cancelled = false
  local comparison = { files = {}, commit_messages = "" }
  local entries = entries_for(session)
  if not session.panel then
    comparison.files[1] = { file = snapshot.file, changes = snapshot.changes }
  end
  local ticks = {}
  local index = 0

  local function finish(err)
    if cancelled then
      return
    end
    if not err then
      local payload = vim.json.decode(snapshot.payload)
      payload.comparison = comparison
      local encoded = vim.json.encode(payload)
      if #encoded > opts.max_input_bytes then
        err = "This comparison is too large for AI summaries (limit: " .. opts.max_input_bytes .. " bytes)."
      else
        snapshot.payload = encoded
        snapshot.key = vim.fn.sha256(snapshot.key .. encoded)
        snapshot.comparison_ticks = ticks
      end
    end
    done(err, snapshot)
  end

  local function messages()
    local panel = session.panel
    local data = panel and panel.data
    local base, target = session.original_revision, session.modified_revision
    if panel and panel.name == "explorer" then
      base, target = data.base_revision, data.target_revision
    end
    -- Uncommitted comparisons have no commit messages of their own.
    if not session.git_root or not target or target == "WORKING" or target:match("^:") then
      finish()
      return
    end
    local range = target
    local args = { "log", "--format=commit %H%n%B" }
    if base and base ~= "WORKING" and not base:match("^:") then
      range = base .. ".." .. target
    else
      args[#args + 1] = "--max-count=1"
    end
    args[#args + 1] = range
    args[#args + 1] = "--"
    require("codediff.core.git.runner").run_async(args, { cwd = session.git_root }, function(err, text)
      vim.schedule(function()
        if cancelled then
          return
        end
        if err then
          finish("Could not read comparison commit messages: " .. err)
        else
          comparison.commit_messages = text
          finish()
        end
      end)
    end)
  end

  local function next_file()
    if cancelled then
      return
    end
    index = index + 1
    local file = entries[index]
    if not file then
      messages()
      return
    end
    local config = panels.comparison(session.panel, file)
    if not config or config.conflict then
      next_file()
      return
    end
    -- The selected block's exact buffer contents are already in snapshot.changes.
    -- Use the same contents here, including unsaved edits and empty deleted sides.
    if file.path == snapshot.file and file.group == (session.panel.data.current_selection or {}).group then
      comparison.files[#comparison.files + 1] = { file = file.path, group = file.group, changes = snapshot.changes }
      vim.schedule(next_file)
      return
    end
    inputs.read(config, {}, nil, function(err, data)
      vim.schedule(function()
        if cancelled then
          return
        end
        if err then
          finish("Could not read comparison file " .. file.path .. ": " .. err)
          return
        end
        local changes, diff_err = context.changes(data.original, data.modified, opts)
        if not changes then
          finish(diff_err)
          return
        end
        for buf, tick in pairs(data.ticks) do
          ticks[buf] = tick
        end
        comparison.files[#comparison.files + 1] = { file = file.path, group = file.group, changes = changes }
        if #vim.json.encode(comparison) > opts.max_input_bytes then
          finish("This comparison is too large for AI summaries (limit: " .. opts.max_input_bytes .. " bytes).")
          return
        end
        next_file()
      end)
    end)
  end

  -- Single-file history can omit the expanded file list. Fetch the entire commit.
  if session.panel and session.panel.name == "history" and #entries == 0 and session.panel.data.current_commit then
    local data = session.panel.data
    panels.load_files(data, data.current_commit, function(err, files)
      vim.schedule(function()
        if cancelled then
          return
        end
        if err then
          finish(err)
          return
        end
        for _, file in ipairs(files) do
          entries[#entries + 1] = vim.tbl_extend("force", file, { commit_hash = data.current_commit })
        end
        next_file()
      end)
    end)
  else
    vim.schedule(next_file)
  end
  return function()
    cancelled = true
  end
end

return M
