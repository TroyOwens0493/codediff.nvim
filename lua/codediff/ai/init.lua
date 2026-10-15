local M = {}
local context = require("codediff.ai.context")
local comparison = require("codediff.ai.comparison")
local provider = require("codediff.ai.provider")
local popup = require("codediff.ai.popup")
local progress = require("codediff.ai.progress")
local states, cache, cache_order = {}, {}, {}
local group

local function options()
  return require("codediff.config").options.ai
end

local function session_for(tabpage)
  return require("codediff.ui.lifecycle").get_session(tabpage)
end

local function notify(message, level)
  vim.notify("CodeDiff AI: " .. message, level or vim.log.levels.INFO)
end

local function state_for(tabpage)
  if not states[tabpage] then
    states[tabpage] = { tabpage = tabpage, generation = 0, status = "idle" }
  end
  return states[tabpage]
end

local function cancel(state)
  progress.stop(state.tabpage)
  state.generation = state.generation + 1
  if state.cancel_context then
    state.cancel_context()
    state.cancel_context = nil
  end
  state.context_snapshot = nil
  if state.cancel then
    local stop = state.cancel
    state.cancel = nil
    stop()
  end
end

function M.cancel(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local state = states[tabpage]
  if state then
    cancel(state)
    state.schedule_generation = (state.schedule_generation or 0) + 1
    state.status = "idle"
  end
  popup.close(tabpage)
end

local function remember(key, summaries)
  if not cache[key] then
    cache_order[#cache_order + 1] = key
  end
  cache[key] = summaries
  while #cache_order > options().cache_size do
    cache[table.remove(cache_order, 1)] = nil
  end
end

local function bind(tabpage, session)
  local lifecycle = require("codediff.ui.lifecycle")
  lifecycle.begin_keymap_scope(tabpage, "ai")
  if not session.merge then
    for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
      lifecycle.set_buf_keymap(tabpage, buf, "n", options().keymap, function()
        M.toggle_summary("what")
      end, { desc = "Toggle AI what summary", silent = true, nowait = true })
      lifecycle.set_buf_keymap(tabpage, buf, "n", options().why_keymap, function()
        M.toggle_summary("why")
      end, { desc = "Toggle AI why summary", silent = true, nowait = true })
    end
  end
  lifecycle.end_keymap_scope(tabpage, "ai")
end

local function generate(tabpage, state, snapshot, force)
  local opts = options()
  if not force and state.snapshot and state.snapshot.key == snapshot.key and (state.status == "ready" or state.status == "loading" and state.cancel or state.status == "error") then
    state.snapshot = snapshot
    return state.status ~= "error"
  end
  cancel(state)
  popup.close(tabpage)
  state.snapshot, state.summaries, state.error = snapshot, nil, nil
  if #snapshot.changes == 0 then
    state.status = "empty"
    return true
  end
  if not force and cache[snapshot.key] then
    state.status, state.summaries = "ready", cache[snapshot.key]
    return true
  end
  local generation = state.generation
  state.status = "loading"
  progress.start(tabpage, snapshot.file)
  state.cancel = provider.summarize(snapshot, opts, function(summary_err, summaries)
    if states[tabpage] ~= state or state.generation ~= generation then
      return
    end
    state.cancel = nil
    progress.stop(tabpage)
    if not context.is_current(state.snapshot, session_for(tabpage)) then
      state.status = "idle"
      return
    end
    state.error, state.summaries = summary_err, summaries
    state.status = summary_err and "error" or "ready"
    if summaries then
      remember(snapshot.key, summaries)
    end
    -- Completion never opens a window. Only the user's mapping does that.
  end)
  return true
end

function M.summarize(tabpage, force)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local opts = options()
  local session = session_for(tabpage)
  if not opts.enabled or not session or session.suspended then
    return false
  end
  local state = state_for(tabpage)
  local snapshot, err = context.capture(session, opts)
  if not snapshot then
    cancel(state)
    popup.close(tabpage)
    state.snapshot, state.summaries = nil, nil
    state.status, state.error = "error", err
    return false
  end
  if state.cancel_context then
    if not force and context.is_current(state.context_snapshot, session) then
      return true
    end
    state.cancel_context()
  end
  -- Cancellation keeps completed results. Reuse them on request while checking
  -- the wider comparison again, just as a ready popup does between refreshes.
  if not force and state.status == "idle" and state.summaries and state.snapshot and context.is_current(state.snapshot, session) then
    state.status = "ready"
  end
  if not state.snapshot or not context.is_current(state.snapshot, session) or state.status == "idle" then
    cancel(state)
    popup.close(tabpage)
    state.snapshot, state.summaries, state.error = snapshot, nil, nil
    state.status = "loading"
    progress.start(tabpage, snapshot.file)
  end
  local generation = state.generation
  state.context_snapshot = snapshot
  state.cancel_context = comparison.capture(session, snapshot, opts, function(comparison_err, captured)
    if states[tabpage] ~= state or state.generation ~= generation then
      return
    end
    state.cancel_context = nil
    state.context_snapshot = nil
    if not context.is_current(captured, session_for(tabpage)) then
      cancel(state)
      state.status = "idle"
      return
    end
    if comparison_err then
      cancel(state)
      popup.close(tabpage)
      state.status, state.error, state.summaries = "error", comparison_err, nil
      return
    end
    generate(tabpage, state, captured, force)
  end)
  return true
end

function M.on_diff_updated(tabpage)
  if not options().enabled then
    return
  end
  local session = session_for(tabpage)
  if not session then
    return
  end
  bind(tabpage, session)
  local state = state_for(tabpage)
  state.schedule_generation = (state.schedule_generation or 0) + 1
  local generation = state.schedule_generation
  if state.snapshot and not context.is_current(state.snapshot, session) then
    cancel(state)
    state.status = "idle"
    popup.close(tabpage)
  end
  if options().auto_summary and not session.merge then
    vim.defer_fn(function()
      if states[tabpage] == state and state.schedule_generation == generation and session_for(tabpage) == session then
        M.summarize(tabpage)
      end
    end, options().debounce_ms)
  end
end

function M.toggle_summary(kind)
  kind = kind or "what"
  assert(kind == "what" or kind == "why", "Summary kind must be 'what' or 'why'")
  local tabpage = vim.api.nvim_get_current_tabpage()
  if popup.is_open(tabpage, kind) then
    popup.close(tabpage)
    return false
  end
  local session = session_for(tabpage)
  if not options().enabled then
    notify("Enable ai.enabled in setup() first.")
    return false
  end
  if not session then
    notify("Open a CodeDiff view first.")
    return false
  end
  if session.merge then
    notify("AI summaries are not available in merge conflict views yet.")
    return false
  end
  local buf = vim.api.nvim_get_current_buf()
  if buf ~= session.original_bufnr and buf ~= session.modified_bufnr then
    notify("Move the cursor to a change in a diff pane.")
    return false
  end
  local state = state_for(tabpage)
  if not state.snapshot or state.status == "idle" or not context.is_current(state.snapshot, session) then
    M.summarize(tabpage)
  end
  if state.status == "error" then
    notify(state.error, vim.log.levels.WARN)
    return false
  elseif state.status == "empty" then
    notify("This file has no changes to summarize.")
    return false
  elseif state.status ~= "ready" then
    notify("Summaries are loading. Press the summary key again when they are ready.")
    return false
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local side = buf == session.original_bufnr and "original" or "modified"
  for id, change in ipairs(state.snapshot.changes) do
    local range = change[side]
    local first = math.min(range.start_line, vim.api.nvim_buf_line_count(buf))
    local last = math.max(first, range.end_line - 1)
    if line >= first and line <= last then
      popup.open(tabpage, state.summaries[id][kind], id, options().popup, kind)
      return true
    end
  end
  notify("Move the cursor to a changed block.")
  return false
end

-- A copy for statuslines and integrations. Never expose credentials or code.
function M.status(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local state = states[tabpage]
  if state and state.snapshot and not context.is_current(state.snapshot, session_for(tabpage)) then
    return { status = "idle", count = 0 }
  end
  return state and { status = state.status, error = state.error, count = state.summaries and #state.summaries or 0 } or { status = "idle", count = 0 }
end

function M.login()
  provider.login(options(), function(err)
    if err then
      notify(err, vim.log.levels.ERROR)
    else
      notify("Signed in with ChatGPT.")
      for tabpage in pairs(states) do
        M.summarize(tabpage, true)
      end
    end
  end)
end

function M.command(action)
  if action == "login" then
    M.login()
  elseif action == "status" then
    provider.account(options(), function(err, account)
      if err then
        notify(err, vim.log.levels.ERROR)
      else
        local login = account and account.type == "chatgpt" and "Signed in with ChatGPT" or "ChatGPT sign-in needed (:CodeDiffAI login)"
        local state = M.status()
        notify(login .. ". Summaries: " .. state.status .. (state.error and " — " .. state.error or ""))
      end
    end)
  elseif action == "refresh" then
    M.summarize(nil, true)
  elseif action == "cancel" then
    M.cancel()
  elseif action == "why" then
    M.toggle_summary("why")
  else
    M.toggle_summary("what")
  end
end

function M.setup()
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
  if not options().enabled then
    for tabpage in pairs(states) do
      M.cancel(tabpage)
      require("codediff.ui.lifecycle").release_keymap_scope(tabpage, "ai")
    end
    states = {}
    provider.stop()
    return
  end
  group = vim.api.nvim_create_augroup("CodeDiffAI", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffOpen",
    callback = function(event)
      M.on_diff_updated(event.data.tabpage)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffFileSelect",
    callback = function(event)
      local existing = states[event.data.tabpage]
      if existing and existing.snapshot and existing.snapshot.file == event.data.path and context.is_current(existing.snapshot, session_for(event.data.tabpage)) then
        M.on_diff_updated(event.data.tabpage)
        return
      end
      M.cancel(event.data.tabpage)
      local state = states[event.data.tabpage]
      if state then
        state.snapshot, state.summaries, state.error = nil, nil, nil
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffClose",
    callback = function(event)
      local tabpage = event.data.tabpage
      M.cancel(tabpage)
      states[tabpage] = nil
      if not next(states) then
        provider.stop()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave", "TabLeave", "WinScrolled", "VimResized", "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(event)
      local filetype = vim.bo[event.buf].filetype
      if event.event:match("^TextChanged") and (filetype == "codediff-explorer" or filetype == "codediff-history") then
        return
      end
      for tabpage in pairs(states) do
        popup.close(tabpage)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      progress.stop_all()
      provider.stop()
    end,
  })
  for tabpage in pairs(require("codediff.ui.lifecycle.session").get_active_diffs()) do
    M.on_diff_updated(tabpage)
  end
end

return M
