local M = {}
local tabline = "%!v:lua.require'codediff.review.panel'.tabline()"
local saved_tabline

function M.number()
  if vim.v.virtnum ~= 0 then
    return "      "
  end
  local locations = vim.b.codediff_review_locations or {}
  local location = locations[vim.v.lnum]
  return string.format("%5s ", location and location.line or "")
end

function M.tabline()
  local parts = {}
  for index, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local label = vim.t[tab].codediff_review and "Guided Review" or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(tab))), ":t")
    if label == "" then
      label = "[No Name]"
    end
    parts[#parts + 1] = string.format("%%#%s#%%%dT %d %s %%T", tab == vim.api.nvim_get_current_tabpage() and "TabLineSel" or "TabLine", index, index, label:gsub("%%", "%%%%"))
  end
  return table.concat(parts) .. "%#TabLineFill#%="
end

function M.restore_tabline()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.t[tab].codediff_review then
      return
    end
  end
  if saved_tabline ~= nil and vim.o.tabline == tabline then
    vim.o.tabline = saved_tabline
  end
  saved_tabline = nil
end

local function buffer(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = filetype
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].modifiable = false
  return buf
end

local function write(buf, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.close(state)
  local tab = state.review_tabpage
  state.review_tabpage = nil
  if tab then
    pcall(vim.api.nvim_del_augroup_by_name, "CodeDiffReviewWindows" .. tab)
  end
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    vim.api.nvim_win_call(vim.api.nvim_tabpage_get_win(tab), function()
      vim.cmd("tabclose!")
    end)
  end
  for _, buf in pairs(state.view_buffers or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  state.view_buffers, state.view_windows, state.display = nil, nil, nil
  state.display_position, state.display_key = nil, nil
  M.restore_tabline()
end

function M.open(state)
  if state.review_tabpage and vim.api.nvim_tabpage_is_valid(state.review_tabpage) then
    vim.api.nvim_set_current_tabpage(state.review_tabpage)
    return
  end
  vim.cmd("tabnew")
  state.review_tabpage = vim.api.nvim_get_current_tabpage()
  local tab = state.review_tabpage
  vim.t[tab].codediff_review = true
  vim.t[tab].tabname, vim.t[tab].tab_name = "Guided Review", "Guided Review"
  if vim.o.tabline == "" then
    saved_tabline = ""
    vim.o.tabline = tabline
  end
  local initial = vim.api.nvim_get_current_buf()
  local prefix = "codediff-review://" .. tab .. "/"
  local bufs = {
    summary = buffer(prefix .. "summary", "codediff-review"),
    stops = buffer(prefix .. "stops", "codediff-review-stops"),
    original = buffer(prefix .. "original", "codediff-review-diff"),
    modified = buffer(prefix .. "modified", "codediff-review-diff"),
  }
  local wins = { summary = vim.api.nvim_get_current_win() }
  vim.api.nvim_win_set_buf(wins.summary, bufs.summary)
  vim.cmd("belowright split")
  wins.modified = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(wins.modified, bufs.modified)
  vim.cmd("leftabove vsplit")
  wins.stops = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(wins.stops, bufs.stops)
  vim.api.nvim_win_set_width(wins.stops, math.min(32, math.max(18, math.floor(vim.o.columns * 0.25))))
  state.layout = state.session.layout or "side-by-side"
  if state.layout ~= "inline" then
    vim.api.nvim_set_current_win(wins.modified)
    local original_right = require("codediff.config").options.diff.original_position == "right"
    vim.cmd(original_right and "rightbelow vsplit" or "leftabove vsplit")
    wins.original = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wins.original, bufs.original)
  end
  for _, win in pairs(wins) do
    vim.wo[win].number, vim.wo[win].relativenumber = false, false
    vim.wo[win].wrap, vim.wo[win].signcolumn = false, "no"
    vim.wo[win].winfixbuf = true
  end
  vim.wo[wins.stops].winfixwidth = true
  vim.wo[wins.stops].winbar = "Stops"
  vim.wo[wins.summary].winfixheight = true
  vim.wo[wins.summary].wrap, vim.wo[wins.summary].linebreak = true, true
  vim.wo[wins.summary].winbar = "Guided Review"
  vim.api.nvim_win_set_height(wins.summary, math.max(3, math.min(7, math.floor(vim.o.lines * 0.18))))
  state.view_buffers, state.view_windows = bufs, wins
  for _, win in pairs({ original = wins.original, modified = wins.modified }) do
    vim.wo[win].number = true
    vim.wo[win].statuscolumn = "%!v:lua.require'codediff.review.panel'.number()"
  end
  vim.api.nvim_set_current_win(wins.stops)
  vim.api.nvim_buf_delete(initial, { force = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = bufs.stops,
    callback = function()
      if state.rendering or state.status ~= "ready" then
        return
      end
      local index = vim.api.nvim_win_get_cursor(wins.stops)[1] - 3
      if state.steps[index] and index ~= state.position then
        require("codediff.review").select(index)
      end
    end,
  })
  local owned = {}
  for _, win in pairs(wins) do
    owned[tostring(win)] = true
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("CodeDiffReviewWindows" .. tab, { clear = true }),
    callback = function(event)
      if not owned[event.match] then
        return
      end
      vim.schedule(function()
        if state.review_tabpage ~= tab then
          return
        end
        require("codediff.review").close(state.tabpage)
      end)
    end,
  })
end

function M.render(state)
  local bufs, wins = state.view_buffers, state.view_windows
  if not bufs or not state.review_tabpage or not vim.api.nvim_tabpage_is_valid(state.review_tabpage) then
    return
  end
  state.rendering = true
  local stops = { "Guided Review", state.status, "" }
  for index, step in ipairs(state.steps or {}) do
    stops[#stops + 1] = string.format("%s %d. [%s] %s", index == state.position and "→" or " ", index, state.seen[index] and "x" or " ", step.title)
  end
  write(bufs.stops, stops)
  if state.steps and state.steps[state.position] then
    vim.api.nvim_win_set_cursor(wins.stops, { state.position + 3, 0 })
  end
  local step = state.steps and state.steps[state.position]
  local summary = { step and string.format("Stop %d/%d · %s", state.position, #state.steps, step.title) or "Guided Review · " .. state.status }
  if state.error then
    summary[#summary + 1] = state.error
  end
  if step then
    summary[#summary + 1] = step.summary
    if step.attention ~= "" then
      summary[#summary + 1] = "Decision: " .. step.attention
    end
    for _, note in ipairs(step.notes) do
      local excerpt = step.excerpts[note.excerpt]
      summary[#summary + 1] = string.format("%s:%d — %s", state.snapshot.files[excerpt.file_id].file, note.line, note.text)
    end
    for index, question in ipairs(step.questions) do
      summary[#summary + 1] = string.format("Question %d: %s", index, question)
    end
    for _, answer in ipairs((state.answers or {})[state.position] or {}) do
      vim.list_extend(summary, { "Q: " .. answer.question, "A: " .. answer.text })
    end
  elseif state.status == "loading" then
    summary[#summary + 1] = "Preparing the guided review…"
  elseif state.status == "empty" then
    summary[#summary + 1] = "This comparison has no changes."
  end
  if state.answer_loading then
    summary[#summary + 1] = "Answer is loading…"
  end
  write(bufs.summary, summary)
  if state.status ~= "ready" then
    write(bufs.original, { "No current stop to display." })
    write(bufs.modified, { "No current stop to display." })
    require("codediff.ui.core").render_diff(bufs.original, bufs.modified, {}, {}, { changes = {} })
    require("codediff.ui.inline").clear(bufs.modified)
    state.display, state.display_position, state.display_key = nil, nil, nil
  elseif step and (state.display_position ~= state.position or state.display_key ~= state.snapshot.key) then
    state.display = require("codediff.review.changes").build(state.snapshot, step)
    state.display_position, state.display_key = state.position, state.snapshot.key
    local display = state.display
    write(bufs.original, display.original)
    write(bufs.modified, display.modified)
    for _, side in ipairs({ "original", "modified" }) do
      vim.b[bufs[side]].codediff_review_locations = display.locations[side]
    end
    local render = require("codediff.ui.view.render")
    if state.layout == "inline" then
      render.render_diff(bufs.original, bufs.modified, display.original, display.modified, "inline")
    else
      vim.api.nvim_win_call(wins.modified, function()
        render.compute_and_render(bufs.original, bufs.modified, display.original, display.modified, true, true, wins.original, wins.modified, false)
      end)
    end
    for _, win in pairs({ original = wins.original, modified = wins.modified }) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
      end
    end
  end
  state.rendering = false
end

function M.jump(state, file_id, excerpt)
  M.render(state)
  local display, wins = state.display, state.view_windows
  if not display then
    return false
  end
  local side = excerpt and excerpt.side or "modified"
  local row = 1
  for index, location in ipairs(display.locations[side]) do
    if location and location.file_id == file_id and (not excerpt or location.change_id == excerpt.change_id and location.line == excerpt.start_line) then
      row = index
      break
    end
  end
  local win = wins[side] or wins.modified
  if state.layout == "inline" and side == "original" then
    for _, block in ipairs(display.blocks) do
      if block.file_id == file_id and (not excerpt or block.change_id == excerpt.change_id) then
        row = block.rows.modified
        break
      end
    end
  end
  row = math.min(row, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)))
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
  return true
end

return M
