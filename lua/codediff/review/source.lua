local M = {}
local comparison = require("codediff.ai.comparison")
local context = require("codediff.ai.context")
local panels = require("codediff.ui.refresh.panel")

-- Object iteration order can change between Neovim processes. Persisted keys cannot.
local function encode(value)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end
  local items = {}
  if vim.islist(value) then
    for _, item in ipairs(value) do
      items[#items + 1] = encode(item)
    end
    return "[" .. table.concat(items, ",") .. "]"
  end
  local keys = vim.tbl_keys(value)
  table.sort(keys)
  for _, key in ipairs(keys) do
    items[#items + 1] = vim.json.encode(key) .. ":" .. encode(value[key])
  end
  return "{" .. table.concat(items, ",") .. "}"
end

local function identity(session)
  local panel = session.panel
  local data = panel and panel.data or {}
  local base, target
  if panel then
    base, target = data.base_revision, data.target_revision or data.current_commit
  else
    base, target = session.original_revision, session.modified_revision
  end
  return {
    root = session.git_root,
    mode = panel and panel.name or "standalone",
    base = base,
    target = target,
    original = not panel and session.original or nil,
    modified = not panel and session.modified or nil,
  }
end

local function file_stamp(path)
  if not path or path == "" then
    return false
  end
  local stat = (vim.uv or vim.loop).fs_stat(path)
  local buf = vim.fn.bufnr(path)
  return { path, stat and { stat.size, stat.mtime, stat.ctime } or false, buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_changedtick(buf) or false }
end

function M.stamp(session)
  local entries = comparison.entries(session)
  local sources = {}
  for _, file in ipairs(entries) do
    local config = panels.comparison(session.panel, file)
    sources[#sources + 1] = { file, config and file_stamp(config.original.absolute), config and file_stamp(config.modified.absolute) }
  end
  if not session.panel then
    sources = { file_stamp(session.original and session.original.absolute), file_stamp(session.modified and session.modified.absolute) }
  end
  local buffers = {}
  for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      -- Selection changes are checked separately; their buffer ids do not define the tour.
      buffers[#buffers + 1] = { buf, vim.api.nvim_buf_get_changedtick(buf) }
    end
  end
  local root = session.git_root
  local git_dir = root and root .. "/.git"
  if git_dir and vim.fn.filereadable(git_dir) == 1 then
    local ok, lines = pcall(vim.fn.readfile, git_dir, "", 1)
    local linked = ok and lines[1] and lines[1]:match("^gitdir: (.+)$")
    if linked then
      git_dir = require("codediff.core.path").make_ref(linked, root).absolute
    end
  end
  return vim.fn.sha256(vim.json.encode({ identity(session), sources, buffers, git_dir and file_stamp(git_dir .. "/index") }))
end

local function with_panel_data(session, data)
  return vim.tbl_extend("force", {}, session, { panel = vim.tbl_extend("force", {}, session.panel, { data = data }) })
end

function M.changed(session, snapshot, done)
  if not session.panel then
    done(M.stamp(session) ~= snapshot.input_stamp)
    return
  end
  -- Poll the file list and source metadata, not every file's contents. Large
  -- reviews only need another full capture when their inputs have changed.
  panels.read(session, function(err, data)
    done(err ~= nil or M.stamp(with_panel_data(session, data)) ~= snapshot.input_stamp)
  end)
end

function M.capture(session, opts, done)
  if session.merge then
    vim.schedule(function()
      done("Guided review is not available in a merge conflict view.")
    end)
    return function() end
  end
  local cancelled, stop
  local function capture(current, snapshot)
    stop = comparison.capture(current, snapshot, vim.tbl_extend("force", opts, { refresh_inputs = true }), function(failure, captured)
      if cancelled then
        return
      end
      if failure then
        done(failure)
        return
      end
      if not require("codediff.ui.refresh.inputs").valid({ ticks = captured.comparison_ticks }) then
        done("The comparison changed while the guide context was loading. Try again.")
        return
      end
      local payload = vim.deepcopy(captured.comparison)
      payload.review_kind = "guide"
      for id, file in ipairs(payload.files) do
        file.id = id
        local empty_side = file.status == "D" and "modified" or (file.status == "A" or file.status == "??") and "original"
        if not current.panel then
          empty_side = current.single_side == "original" and "modified" or current.single_side == "modified" and "original" or nil
        end
        -- Neovim buffers always contain at least one line. That placeholder is not
        -- source code on the absent side of an added or deleted file.
        if empty_side then
          for _, change in ipairs(file.changes) do
            local range = change[empty_side]
            range.end_line, range.lines, range.context = range.start_line, {}, {}
          end
        end
      end
      local encoded = vim.json.encode(payload)
      done(nil, {
        files = payload.files,
        payload = encoded,
        key = vim.fn.sha256(encode({ 1, identity(current), payload, opts.model or "", opts.effort })),
        stamp = M.stamp(session),
        input_stamp = M.stamp(current),
      })
    end)
  end
  if session.panel then
    -- Collect fresh inputs while the source tab is suspended, without changing
    -- its selection, windows, or panel.
    require("codediff.ui.refresh.panel").read(session, function(err, data)
      if cancelled then
        return
      end
      if err then
        done(err)
        return
      end
      local current = with_panel_data(session, data)
      capture(current, { file = "", changes = {}, payload = "{}", key = "" })
    end)
  else
    require("codediff.ui.refresh.inputs").read(session, { full = true }, nil, function(err, data)
      if cancelled then
        return
      end
      if err then
        done(err)
        return
      end
      local changes, failure = context.changes(data.original, data.modified, opts)
      if not changes then
        done(failure)
        return
      end
      local path = session.modified and session.modified.absolute ~= "" and session.modified or session.original
      capture(session, { file = path.relative ~= "" and path.relative or path.absolute, changes = changes, payload = "{}", key = "" })
    end)
  end
  return function()
    cancelled = true
    if stop then
      stop()
    end
  end
end

return M
