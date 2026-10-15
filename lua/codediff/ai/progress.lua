-- One animation timer shared by the explorer rows with active requests.
local M = {}
local active = {}
local timer
local frame = 1
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function redraw(tabpage)
  if not vim.api.nvim_tabpage_is_valid(tabpage) or vim.api.nvim_get_current_tabpage() ~= tabpage then
    return
  end
  local panel = require("codediff.ui.lifecycle").get_panel_view(tabpage)
  if panel and panel.tree and not panel.is_hidden and vim.api.nvim_buf_is_valid(panel.bufnr) then
    panel.tree:render()
  end
end

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

function M.label(tabpage, path)
  if require("codediff.config").options.ai.loading_indicator and active[tabpage] and active[tabpage] == path then
    return frames[frame] .. " AI"
  end
end

function M.start(tabpage, path)
  if not require("codediff.config").options.ai.loading_indicator or require("codediff.ui.lifecycle").get_panel_name(tabpage) ~= "explorer" then
    return
  end
  active[tabpage] = path
  redraw(tabpage)
  if not timer then
    timer = (vim.uv or vim.loop).new_timer()
    timer:start(
      100,
      100,
      vim.schedule_wrap(function()
        frame = frame % #frames + 1
        for tab in pairs(active) do
          redraw(tab)
        end
      end)
    )
  end
end

function M.stop(tabpage)
  if not active[tabpage] then
    return
  end
  active[tabpage] = nil
  if not next(active) then
    stop_timer()
  end
  redraw(tabpage)
end

function M.stop_all()
  active = {}
  stop_timer()
end

return M
