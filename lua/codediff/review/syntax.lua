local M = {}
M.namespace = vim.api.nvim_create_namespace("codediff-review-syntax")

local function legacy(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ok, result = pcall(vim.api.nvim_buf_call, buf, function()
    -- Load syntax without FileType events or language-server attachment.
    vim.cmd.runtime({ "syntax/" .. ft .. ".vim", bang = true })
    vim.cmd("syntax sync fromstart")
    local highlights = {}
    for row, line in ipairs(lines) do
      local tokens, first, previous = {}, 1, 0
      for col = 1, #line + 1 do
        local id = col <= #line and vim.fn.synID(row, col, true) or 0
        if id ~= previous then
          if previous ~= 0 then
            tokens[#tokens + 1] = { start_col = first, end_col = col - 1, hl_group = vim.fn.synIDattr(previous, "name") }
          end
          first, previous = col, id
        end
      end
      highlights[row] = tokens
    end
    return highlights
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  return ok and result or {}
end

local function capture(file, range)
  local lines = range.context or range.lines
  local ft = vim.filetype.match({ filename = file, contents = lines })
  if not ft then
    return {}
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local result = require("codediff.ui.inline").compute_syntax_highlights(lines, lang)
  if not next(result) then
    return legacy(lines, ft)
  end
  for _, tokens in pairs(result) do
    for _, token in ipairs(tokens) do
      token.hl_group = token.hl_group .. "." .. lang
    end
  end
  return result
end

function M.compute(display)
  local result = { original = {}, modified = {} }
  for _, side in ipairs({ "original", "modified" }) do
    local captures = {}
    for _, block in ipairs(display.blocks) do
      if block.change then
        local range = block.change[side]
        captures[block.file_id .. ":" .. block.change_id] = {
          first = range.context_start_line or range.start_line,
          tokens = capture(block.file.file, range),
        }
      end
    end
    -- Headers and separators have no source location and receive no syntax.
    for row, location in ipairs(display.locations[side]) do
      if location then
        local source = captures[location.file_id .. ":" .. location.change_id]
        result[side][row] = source.tokens[location.line - source.first + 1]
      end
    end
  end
  return result
end

function M.apply(buf, highlights)
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
  for row, tokens in pairs(highlights or {}) do
    for _, token in ipairs(tokens) do
      if token.end_col >= token.start_col then
        vim.api.nvim_buf_set_extmark(buf, M.namespace, row - 1, token.start_col - 1, {
          end_col = token.end_col,
          hl_group = token.hl_group,
          priority = 100,
          hl_mode = "combine",
        })
      end
    end
  end
end

return M
