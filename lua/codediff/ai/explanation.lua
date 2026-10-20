-- An explicit selection request owns its window and cancellation separately
-- from background change summaries.
local M = {}
local selection = require("codediff.ai.selection")
local states = {}

function M.close(tabpage)
  local state = states[tabpage]
  states[tabpage] = nil
  if not state then
    return
  end
  if state.cancel then
    state.cancel()
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
end

function M.invalidate(tabpage, session)
  local state = states[tabpage]
  if state and not selection.is_current(state.snapshot, session) then
    M.close(tabpage)
  end
end

function M.open(tabpage, snapshot, opts)
  M.close(tabpage)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "codediff-explanation"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Generating line explanations…" })
  vim.bo[buf].modifiable = false
  local width = math.max(1, math.min(opts.popup.max_width, vim.o.columns - 4))
  local height = math.max(1, math.floor((vim.o.lines - 4) * 0.6))
  local float = {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = opts.popup.border,
    zindex = 70,
  }
  if opts.popup.border ~= "none" and opts.popup.border ~= "" then
    float.title = " Explain lines " .. snapshot.first_line .. "–" .. snapshot.last_line .. " · q/Esc close "
    float.title_pos = "left"
  end
  local win = vim.api.nvim_open_win(buf, true, float)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  local state = { snapshot = snapshot, win = win }
  states[tabpage] = state
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      M.close(tabpage)
    end, { buffer = buf, silent = true, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if states[tabpage] == state then
        state.win = nil
        M.close(tabpage)
      end
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
    if not vim.api.nvim_buf_is_valid(buf) then
      M.close(tabpage)
      return
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, err and vim.split("CodeDiff AI: " .. err, "\n", { plain = true }) or lines)
    vim.bo[buf].modifiable = false
  end)
end

return M
