-- Selection requests own their panes and cancellation independently of summaries.
local M = {}
local selection = require("codediff.ai.selection")
local states = {}

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- Expand tabs in source columns. Keep code whitespace and break prose at spaces.
local function wrap(text, width, tabstop, prose)
  local expanded, column = {}, 0
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if char == "\t" then
      char = string.rep(" ", tabstop - column % tabstop)
    end
    expanded[#expanded + 1] = char
    column = column + vim.fn.strdisplaywidth(char)
  end
  local rows, row = {}, ""
  for char in table.concat(expanded):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if row ~= "" and vim.fn.strdisplaywidth(row .. char) > width then
      local space = prose and row:match("^.*()%s")
      if space and space > 1 then
        rows[#rows + 1] = row:sub(1, space - 1)
        row = row:sub(space + 1)
      else
        rows[#rows + 1], row = row, ""
      end
    end
    row = row .. char
  end
  rows[#rows + 1] = row
  return rows
end

function M.close(tabpage)
  local state = states[tabpage]
  states[tabpage] = nil
  if not state then
    return
  end
  local focused = vim.tbl_contains(state.wins, vim.api.nvim_get_current_win())
  if state.cancel then
    state.cancel()
  end
  vim.api.nvim_del_augroup_by_id(state.group)
  for index = #state.wins, 1, -1 do
    local win = state.wins[index]
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  if focused and vim.api.nvim_win_is_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end
end

function M.invalidate(tabpage, session)
  local state = states[tabpage]
  if state and not selection.is_current(state.snapshot, session) then
    M.close(tabpage)
  end
end

local function render(state)
  local active = vim.api.nvim_get_current_win() == state.wins[2] and state.wins[2] or state.wins[3]
  local view = vim.api.nvim_win_call(active, vim.fn.winsaveview)
  local cursor_index, top_index = 1, 1
  for index, row in ipairs(state.starts or {}) do
    if row <= view.lnum then
      cursor_index = index
    end
    if row <= view.topline then
      top_index = index
    end
  end
  local code, explanations, starts = {}, {}, {}
  for index, entry in ipairs(state.snapshot.lines) do
    starts[index] = #code + 1
    local left = wrap(entry.text, state.code_width, state.snapshot.tabstop, false)
    local right = wrap(state.explanations and state.explanations[index] or "", state.text_width, 8, true)
    if index == 1 and state.message then
      right = wrap(state.message, state.text_width, 8, true)
    end
    for row = 1, math.max(#left, #right) do
      code[#code + 1], explanations[#explanations + 1] = left[row] or "", right[row] or ""
    end
    if index < #state.snapshot.lines then
      code[#code + 1], explanations[#explanations + 1] = "", ""
    end
  end
  state.starts = starts
  set_lines(state.code_buf, code)
  set_lines(state.text_buf, explanations)
  for index = 2, 3 do
    vim.api.nvim_win_call(state.wins[index], function()
      vim.fn.winrestview({ lnum = starts[cursor_index], col = 0, topline = starts[top_index], leftcol = 0 })
    end)
  end
end

local function layout(state, border)
  local width = math.min(math.max(7, math.floor(vim.o.columns * 0.9)), math.max(7, vim.o.columns - 2))
  local height = math.max(3, math.min(math.floor(vim.o.lines * 0.8), vim.o.lines - vim.o.cmdheight - 2))
  state.code_width = math.max(1, math.floor((width - 5) * 0.45))
  state.text_width = math.max(1, width - state.code_width - 5)
  local frame = {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = border,
    focusable = false,
    zindex = 70,
  }
  if border ~= "none" and border ~= "" then
    frame.title = " Explain · " .. state.snapshot.file .. " · q/Esc close "
    frame.title_pos = "left"
  end
  vim.api.nvim_win_set_config(state.wins[1], frame)
  local divider = string.rep(" ", state.code_width + 2) .. "│"
  local rows = { " Code" .. string.rep(" ", math.max(0, state.code_width - 3)) .. "│ Explanation" }
  for _ = 2, height do
    rows[#rows + 1] = divider
  end
  set_lines(state.frame_buf, rows)
  for index, col in ipairs({ 1, state.code_width + 4 }) do
    vim.api.nvim_win_set_config(state.wins[index + 1], {
      relative = "win",
      win = state.wins[1],
      row = 1,
      col = col,
      width = index == 1 and state.code_width or state.text_width,
      height = height - 2,
      style = "minimal",
      border = "none",
      zindex = 71,
    })
  end
  render(state)
end

function M.open(tabpage, snapshot, opts)
  M.close(tabpage)
  local state = {
    snapshot = snapshot,
    source_win = vim.api.nvim_get_current_win(),
    wins = {},
    message = "Generating line explanations…",
    group = vim.api.nvim_create_augroup("CodeDiffExplanation" .. tabpage, { clear = true }),
  }
  states[tabpage] = state
  for index, filetype in ipairs({ "codediff-explanation-frame", "codediff-explanation-code", "codediff-explanation" }) do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = filetype
    local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = 1, height = 1, style = "minimal" })
    state.wins[index] = win
    if index == 1 then
      state.frame_buf = buf
    elseif index == 2 then
      state.code_buf = buf
      vim.bo[buf].syntax = snapshot.filetype
    else
      state.text_buf = buf
    end
    vim.wo[win].wrap = false
    vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
    for _, key in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", key, function()
        M.close(tabpage)
      end, { buffer = buf, silent = true, nowait = true })
    end
    vim.api.nvim_create_autocmd("WinClosed", {
      group = state.group,
      pattern = tostring(win),
      callback = function()
        M.close(tabpage)
      end,
    })
  end
  layout(state, opts.popup.border)
  vim.api.nvim_set_current_win(state.wins[3])
  -- scrollbind would also bind the underlying diff panes, so sync only this pair.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = state.group,
    pattern = { tostring(state.wins[2]), tostring(state.wins[3]) },
    callback = function(event)
      local from = tonumber(event.match)
      local to = from == state.wins[2] and state.wins[3] or state.wins[2]
      local view = vim.api.nvim_win_call(from, vim.fn.winsaveview)
      vim.api.nvim_win_set_cursor(to, { vim.api.nvim_win_get_cursor(from)[1], 0 })
      vim.api.nvim_win_call(to, function()
        vim.fn.winrestview({ topline = view.topline, leftcol = 0 })
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = state.group,
    callback = function()
      layout(state, opts.popup.border)
    end,
  })
  state.cancel = require("codediff.ai.provider").explain(snapshot, opts, function(err, lines)
    if states[tabpage] ~= state then
      return
    end
    state.cancel = nil
    local session = require("codediff.ui.lifecycle").get_session(tabpage)
    if not selection.is_current(snapshot, session) then
      M.close(tabpage)
      return
    end
    state.message = err and "CodeDiff AI: " .. err or nil
    state.explanations = lines
    render(state)
  end)
end

return M
