local M = {}
local windows = {}
local kinds = {}

function M.close(tabpage)
  local win = windows[tabpage]
  windows[tabpage] = nil
  kinds[tabpage] = nil
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

function M.is_open(tabpage, kind)
  return windows[tabpage] and vim.api.nvim_win_is_valid(windows[tabpage]) and (not kind or kinds[tabpage] == kind) or false
end

function M.open(tabpage, summary, id, opts, kind)
  M.close(tabpage)
  local source_win = vim.api.nvim_get_current_win()
  local width = math.max(1, math.min(opts.max_width, vim.api.nvim_win_get_width(source_win) - 4, vim.o.columns - 4))
  local lines, line = {}, ""
  for word in summary:gmatch("%S+") do
    local candidate = line == "" and word or line .. " " .. word
    if line ~= "" and vim.fn.strdisplaywidth(candidate) > width then
      lines[#lines + 1] = line
      line = word
    else
      line = candidate
    end
  end
  lines[#lines + 1] = line
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "codediff-summary"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local height = math.min(#lines, math.max(1, math.floor(vim.o.lines / 3)))
  local screen_row = vim.api.nvim_win_call(source_win, vim.fn.winline)
  local above = screen_row + height + 3 > vim.api.nvim_win_get_height(source_win)
  local border = opts.border
  local float = {
    relative = "win",
    win = source_win,
    bufpos = { vim.api.nvim_win_get_cursor(source_win)[1] - 1, 0 },
    row = above and -1 or 1,
    col = 0,
    anchor = above and "SW" or "NW",
    width = width,
    height = height,
    style = "minimal",
    border = border,
    focusable = false,
    zindex = 60,
    noautocmd = true,
  }
  if border ~= "none" and border ~= "" then
    float.title = " Change " .. id .. " · " .. (kind == "why" and "Why" or "What") .. " "
    float.title_pos = "left"
  end
  local win = vim.api.nvim_open_win(buf, false, float)
  vim.wo[win].wrap = true
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  windows[tabpage] = win
  kinds[tabpage] = kind or "what"
  return win
end

return M
