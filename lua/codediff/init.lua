-- vscode-diff main API
local M = {}

-- Configuration setup
function M.setup(opts)
  local config = require("codediff.config")
  config.setup(opts)

  local render = require("codediff.ui")
  render.setup_highlights()
  if config.options.ai.enabled or package.loaded["codediff.ai"] then
    require("codediff.ai").setup()
  end
end

-- Toggle what changed for the block under the cursor (existing API).
function M.toggle_summary()
  return M.toggle_what_summary()
end

-- Toggle a floating description of what changed in the current block.
function M.toggle_what_summary()
  return require("codediff.ai").toggle_summary("what")
end

-- Toggle a floating explanation of the current block's broader purpose.
function M.toggle_why_summary()
  return require("codediff.ai").toggle_summary("why")
end

-- Generate both summaries for each change in the current file. opts.force bypasses the cache.
function M.summarize(opts)
  return require("codediff.ai").summarize(nil, opts and opts.force)
end

-- Read summary state for a statusline or another integration.
function M.ai_status(tabpage)
  return require("codediff.ai").status(tabpage)
end

function M.ai_login()
  return require("codediff.ai").login()
end

-- Navigate to next hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.next_hunk()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.next_hunk()
end

-- Navigate to previous hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.prev_hunk()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.prev_hunk()
end

-- Navigate to next file in explorer/history mode
-- In single-file history mode, navigates to next commit instead
-- Returns true if navigation succeeded, false otherwise
function M.next_file()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.next_file()
end

-- Navigate to previous file in explorer/history mode
-- In single-file history mode, navigates to previous commit instead
-- Returns true if navigation succeeded, false otherwise
function M.prev_file()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.prev_file()
end

return M
