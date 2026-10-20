local M = {}
local source = require("codediff.review.source")
local panel = require("codediff.review.panel")
local store = require("codediff.review.store")
local provider = require("codediff.ai.provider")
local states = {}
local group

local function state_for(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  if states[tabpage] then
    return states[tabpage]
  end
  for _, state in pairs(states) do
    if state.review_tabpage == tabpage then
      return state
    end
  end
end

local function options()
  return require("codediff.config").options.ai
end

local function session_for(tabpage)
  return require("codediff.ui.lifecycle").get_session(tabpage)
end

local function notify(message)
  vim.notify("CodeDiff review: " .. message, vim.log.levels.WARN)
  return false
end

local function unhighlight(state)
  for _, buf in ipairs(state.highlights or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, state.namespace, 0, -1)
    end
  end
  state.highlights = {}
end

local function stop(state)
  state.generation = state.generation + 1
  for _, field in ipairs({ "cancel_capture", "cancel_request", "cancel_check", "cancel_answer" }) do
    if state[field] then
      state[field]()
      state[field] = nil
    end
  end
  state.answer_loading, state.pending, state.checking, state.after_check = nil, nil, nil, nil
end

local function stale(state, reason)
  stop(state)
  unhighlight(state)
  state.status = "stale"
  state.error = reason or "The comparison changed. Use :CodeDiffReview refresh to generate a new guide."
  panel.render(state)
end

local function is_live(state, generation)
  return states[state.tabpage] == state and session_for(state.tabpage) == state.session and state.generation == generation
end

local function save(state)
  if state.status == "ready" then
    store.write(state)
  end
end

local function check(state, done, force)
  if state.checking then
    if done then
      table.insert(state.after_check, done)
    end
    return true
  end
  if not force and state.snapshot.stamp == source.stamp(state.session) then
    if done then
      done()
    end
    return true
  end
  local generation = state.generation
  state.checking = true
  state.after_check = done and { done } or {}
  state.cancel_check = source.capture(state.session, options(), function(err, snapshot)
    if not is_live(state, generation) then
      return
    end
    state.checking, state.cancel_check = nil, nil
    if err or snapshot.key ~= state.snapshot.key then
      stale(state, err and (err .. " Regenerate the guide.") or nil)
      return
    end
    state.snapshot.stamp = snapshot.stamp
    state.snapshot.input_stamp = snapshot.input_stamp
    local callbacks = state.after_check
    state.after_check = nil
    for _, callback in ipairs(callbacks) do
      if is_live(state, generation) then
        callback()
      end
    end
  end)
  return true
end

function M.on_updated(tabpage, force)
  local state = states[tabpage]
  if not state or state.status ~= "ready" or state.session ~= session_for(tabpage) then
    return
  end
  if state.session.refresh and state.session.refresh.loading then
    return
  end
  check(state, nil, force)
end

local function poll(state)
  if state.poll then
    return
  end
  state.poll = (vim.uv or vim.loop).new_timer()
  state.poll:start(
    2000,
    2000,
    vim.schedule_wrap(function()
      if
        states[state.tabpage] == state
        and state.status == "ready"
        and not state.poll_reading
        and state.review_tabpage
        and vim.api.nvim_get_current_tabpage() == state.review_tabpage
      then
        state.poll_reading = true
        local generation = state.generation
        source.changed(state.session, state.snapshot, function(changed)
          state.poll_reading = nil
          if is_live(state, generation) and changed then
            M.on_updated(state.tabpage, true)
          end
        end)
      end
    end)
  )
end

function M.setup()
  if group then
    vim.api.nvim_del_augroup_by_id(group)
  end
  group = vim.api.nvim_create_augroup("CodeDiffReview", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffUpdated",
    callback = function(event)
      M.on_updated(event.data.tabpage)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffClose",
    callback = function(event)
      M.close(event.data.tabpage, true)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost", "TabEnter" }, {
    group = group,
    callback = function()
      for tabpage in pairs(states) do
        M.on_updated(tabpage)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      vim.schedule(function()
        for _, state in pairs(states) do
          if state.review_tabpage and not vim.api.nvim_tabpage_is_valid(state.review_tabpage) then
            M.close(state.tabpage)
          end
        end
        panel.restore_tabline()
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, state in pairs(states) do
        save(state)
        stop(state)
        if state.poll then
          state.poll:stop()
          state.poll:close()
          state.poll = nil
        end
      end
    end,
  })
  if not options().enabled then
    for tabpage in pairs(states) do
      M.close(tabpage, true)
    end
  end
end

function M.start(opts)
  opts = opts or {}
  local state = state_for()
  local tabpage = state and state.tabpage or vim.api.nvim_get_current_tabpage()
  local session = state and state.session or session_for(tabpage)
  if not options().enabled then
    return notify("Enable ai.enabled in setup() first.")
  end
  if not session then
    return notify("Open a CodeDiff view first.")
  end
  if session.merge then
    return notify("Guided review is not available in a merge conflict view.")
  end
  if not group then
    M.setup()
  end
  state = state or states[tabpage]
  if state and state.status == "loading" and not opts.force then
    panel.open(state)
    poll(state)
    panel.render(state)
    return true
  end
  if state then
    stop(state)
    unhighlight(state)
  end
  state = state or { tabpage = tabpage, generation = 0, namespace = vim.api.nvim_create_namespace("CodeDiffReviewExcerpt" .. tabpage) }
  states[tabpage] = state
  state.session, state.status, state.error = session, "loading", nil
  state.steps, state.snapshot, state.answers = nil, nil, {}
  state.position, state.seen = 1, {}
  panel.open(state)
  poll(state)
  panel.render(state)
  local generation = state.generation
  state.cancel_capture = source.capture(session, options(), function(err, snapshot)
    if not is_live(state, generation) then
      return
    end
    state.cancel_capture = nil
    if err then
      state.status, state.error = "error", err
      panel.render(state)
      return
    end
    state.snapshot = snapshot
    if #snapshot.files == 0 then
      state.status = "empty"
      panel.render(state)
      return
    end
    local cached = not opts.force and store.read(snapshot)
    if cached then
      state.steps, state.position, state.seen = cached.steps, cached.position, cached.seen
      state.status = "ready"
      panel.render(state)
      return
    end
    state.cancel_request = provider.review(snapshot, options(), function(failure, steps)
      if not is_live(state, generation) then
        return
      end
      state.cancel_request = nil
      if failure then
        state.status, state.error = "error", failure
        panel.render(state)
        return
      end
      -- Re-read the whole comparison: another file may have changed during inference.
      check(state, function()
        state.status, state.steps = "ready", steps
        save(state)
        panel.render(state)
      end, true)
    end)
  end)
  return true
end

function M.status(tabpage)
  local state = state_for(tabpage)
  if not state then
    return { status = "idle", position = 0, count = 0, seen = {}, open = false }
  end
  return {
    status = state.status,
    error = state.error,
    position = state.position,
    count = state.steps and #state.steps or 0,
    seen = vim.deepcopy(state.seen),
    open = state.review_tabpage ~= nil and vim.api.nvim_tabpage_is_valid(state.review_tabpage),
    tabpage = state.review_tabpage,
    source_tabpage = state.tabpage,
    answer_loading = state.answer_loading == true,
  }
end

function M.steps(tabpage)
  local state = state_for(tabpage)
  local steps = state and vim.deepcopy(state.steps or {}) or {}
  for _, step in ipairs(steps) do
    for _, excerpt in ipairs(step.excerpts) do
      local file = state.snapshot.files[excerpt.file_id]
      excerpt.path, excerpt.group = file.file, file.group
    end
    for i, id in ipairs(step.files) do
      local file = state.snapshot.files[id]
      step.files[i] = { path = file.file, group = file.group }
    end
  end
  return steps
end

local function ready()
  local state = state_for()
  if not state or state.status ~= "ready" then
    notify("Generate a current guide first with :CodeDiffReview start.")
    return nil
  end
  return state
end

local function open_file(state, file, excerpt)
  state.navigation = (state.navigation or 0) + 1
  local navigation = state.navigation
  check(state, function()
    if state.status ~= "ready" or state.navigation ~= navigation then
      return
    end
    panel.jump(state, file.id, excerpt)
  end, true)
  return true
end

function M.open_excerpt(index)
  local state = ready()
  if not state then
    return false
  end
  index = index or 1
  local step = state.steps[state.position]
  local excerpt = step.excerpts[index]
  if not excerpt then
    return notify("This step has no excerpt " .. tostring(index) .. ".")
  end
  return open_file(state, state.snapshot.files[excerpt.file_id], excerpt)
end

function M.open_file(index)
  local state = ready()
  if not state then
    return false
  end
  local id = state.steps[state.position].files[index or 1]
  if not id then
    return notify("This step has no file " .. tostring(index or 1) .. ".")
  end
  return open_file(state, state.snapshot.files[id])
end

function M.select(index)
  local state = ready()
  if not state then
    return false
  end
  if type(index) ~= "number" or index % 1 ~= 0 or not state.steps[index] then
    return notify("Select a valid review step number.")
  end
  state.position = index
  unhighlight(state)
  save(state)
  panel.open(state)
  panel.render(state)
  local step = state.steps[index]
  if #step.excerpts > 0 then
    return M.open_excerpt(1)
  end
  if #step.files > 0 then
    return M.open_file(1)
  end
  return true
end

function M.step(direction)
  local state = ready()
  if not state then
    return false
  end
  local index = state.position + direction
  if index < 1 or index > #state.steps then
    return false
  end
  return M.select(index)
end

function M.mark_seen(value)
  local state = ready()
  if not state then
    return false
  end
  state.seen[state.position] = value ~= false or nil
  save(state)
  panel.render(state)
  return true
end

function M.ask(question)
  local state = ready()
  if not state then
    return false
  end
  if type(question) ~= "string" or vim.trim(question) == "" or #question > 4000 then
    return notify("Supply a question of 1 to 4000 characters.")
  end
  if state.answer_loading then
    return notify("An answer is already loading.")
  end
  local position = state.position
  state.answer_loading = true
  panel.render(state)
  return check(state, function()
    local generation = state.generation
    local payload = vim.json.decode(state.snapshot.payload)
    payload.step, payload.question = state.steps[position], question
    state.cancel_answer = provider.review_answer({ payload = vim.json.encode(payload) }, options(), function(err, answer)
      if not is_live(state, generation) then
        return
      end
      state.cancel_answer, state.answer_loading = nil, nil
      check(state, function()
        state.answers[position] = state.answers[position] or {}
        table.insert(state.answers[position], { question = question, text = err or answer })
        panel.render(state)
      end, true)
    end)
  end, true)
end

function M.cancel(tabpage)
  local state = state_for(tabpage)
  if not state then
    return false
  end
  stop(state)
  if state.status == "loading" then
    state.status = "cancelled"
  end
  panel.render(state)
  return true
end

function M.close(tabpage, dispose)
  local state = state_for(tabpage)
  if not state then
    return false
  end
  save(state)
  M.cancel(state.tabpage)
  if state.poll then
    state.poll:stop()
    state.poll:close()
    state.poll = nil
  end
  unhighlight(state)
  panel.close(state)
  if dispose then
    states[state.tabpage] = nil
  end
  return true
end

function M.command(args)
  local action = args[1] or "start"
  if action == "start" or action == "refresh" then
    return M.start({ force = action == "refresh" })
  elseif action == "next" then
    return M.step(1)
  elseif action == "prev" then
    return M.step(-1)
  elseif action == "step" then
    return M.select(tonumber(args[2]))
  elseif action == "excerpt" then
    return M.open_excerpt(tonumber(args[2]))
  elseif action == "file" then
    return M.open_file(tonumber(args[2]))
  elseif action == "seen" then
    return M.mark_seen()
  elseif action == "unseen" then
    return M.mark_seen(false)
  elseif action == "ask" then
    return M.ask(table.concat(args, " ", 2))
  elseif action == "close" then
    return M.close()
  elseif action == "cancel" then
    return M.cancel()
  elseif action == "status" then
    vim.notify(vim.inspect(M.status()))
    return true
  end
  return notify("Use :CodeDiffReview start|refresh|next|prev|step N|excerpt N|file N|seen|unseen|ask QUESTION|status|cancel|close")
end

return M
