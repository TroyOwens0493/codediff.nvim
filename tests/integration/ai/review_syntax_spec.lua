local panel = require("codediff.review.panel")
local syntax = require("codediff.review.syntax")

for _, layout in ipairs({ "side-by-side", "inline" }) do
  describe("Guided review syntax / " .. layout, function()
    local state, source_tab, get_parser, filetype_events, review_events
    local function file(path, old, new)
      return {
        file = path,
        changes = {
          {
            original = { start_line = 8, end_line = 9, lines = { old }, context_start_line = 7, context = { "", old, "" } },
            modified = { start_line = 8, end_line = 9, lines = { new }, context_start_line = 7, context = { "", new, "" } },
          },
        },
      }
    end
    before_each(function()
      source_tab = vim.api.nvim_get_current_tabpage()
      get_parser = vim.treesitter.get_string_parser
      filetype_events = {}
      review_events = {}
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("ReviewSyntaxTest", { clear = true }),
        callback = function(event)
          filetype_events[#filetype_events + 1] = event.match
        end,
      })
      vim.api.nvim_create_autocmd("User", {
        group = "ReviewSyntaxTest",
        pattern = { "CodeDiffReviewFileSelect", "CodeDiffReviewClose" },
        callback = function(event)
          review_events[#review_events + 1] = { name = event.match, data = event.data }
        end,
      })
      require("codediff.ui.highlights").setup()
      state = {
        tabpage = source_tab,
        session = { layout = layout },
        status = "ready",
        position = 1,
        seen = {},
        snapshot = {
          key = "syntax-test",
          files = {
            file("sample.lua", "local value = 1", "local value = 2"),
            file("sample.vim", "let g:value = 1", "let g:value = 2"),
            file("plain.txt", "old text", "new text"),
          },
        },
        steps = {
          { title = "Mixed languages", summary = "Related changes.", attention = "", excerpts = {}, files = { 1, 2 }, notes = {}, questions = {} },
          { title = "Plain text", summary = "Text changes.", attention = "", excerpts = {}, files = { 3 }, notes = {}, questions = {} },
        },
      }
      panel.open(state)
    end)
    after_each(function()
      vim.treesitter.get_string_parser = get_parser
      vim.api.nvim_del_augroup_by_name("ReviewSyntaxTest")
      if state then
        panel.close(state)
      end
      vim.api.nvim_set_current_tabpage(source_tab)
    end)

    local function tokens(side)
      return vim.api.nvim_buf_get_extmarks(state.view_buffers[side], syntax.namespace, 0, -1, { details = true })
    end

    local function assert_languages(patterns)
      for _, side in ipairs({ "original", "modified" }) do
        local found = {}
        for _, mark in ipairs(tokens(side)) do
          local location = state.display.locations[side][mark[2] + 1]
          assert.is_truthy(location, "Headers and separators must not inherit code syntax")
          assert.is_truthy(mark[4].hl_group:match(patterns[location.file_id]), mark[4].hl_group)
          found[location.file_id] = true
        end
        assert.same({ true, true }, found)
        assert.is_false(vim.bo[state.view_buffers[side]].modifiable)
      end
      for _, ft in ipairs(filetype_events) do
        assert.is_true(ft ~= "lua" and ft ~= "vim", "Source FileType events must not attach language servers")
      end
      if layout == "inline" then
        local found = {}
        local marks = vim.api.nvim_buf_get_extmarks(state.view_buffers.modified, require("codediff.ui.inline").ns_inline, 0, -1, { details = true })
        for _, mark in ipairs(marks) do
          for _, chunks in ipairs(mark[4].virt_lines or {}) do
            for _, chunk in ipairs(chunks) do
              if chunk[2] and chunk[2]:match("^CodeDiffInline_") then
                if chunk[1]:find("local", 1, true) then
                  found[1] = true
                end
                if chunk[1]:find("let", 1, true) then
                  found[2] = true
                end
              end
            end
          end
        end
        assert.same({ true, true }, found, "Deleted code must retain syntax colors in inline mode")
      end
    end

    it("highlights each language on both sides and on inline deleted lines", function()
      panel.render(state)
      assert_languages({ "%.lua$", "%.vim$" })
      state.position = 2
      panel.render(state)
      assert.same({}, tokens("original"))
      assert.same({}, tokens("modified"))
    end)

    it("uses Vim syntax when Tree-sitter parsers are unavailable", function()
      vim.treesitter.get_string_parser = function()
        error("Parser is not installed")
      end
      panel.render(state)
      assert_languages({ "^lua", "^vim" })
      state.status = "stale"
      panel.render(state)
      assert.same({}, tokens("original"))
      assert.same({}, tokens("modified"))
    end)

    it("reports the active file across navigation, cursor movement, and closing", function()
      panel.render(state)
      local tab = state.review_tabpage
      assert.same({ tabpage = tab, source_tabpage = source_tab, path = "sample.lua" }, review_events[#review_events].data)
      panel.jump(state, 2)
      assert.equals("sample.vim", review_events[#review_events].data.path)
      vim.api.nvim_set_current_win(state.view_windows.modified)
      for row, location in ipairs(state.display.locations.modified) do
        if location and location.file_id == 1 then
          vim.api.nvim_win_set_cursor(state.view_windows.modified, { row, 0 })
          break
        end
      end
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.view_buffers.modified })
      assert.equals("sample.lua", review_events[#review_events].data.path)
      vim.api.nvim_set_current_win(state.view_windows.summary)
      assert.equals("sample.lua", review_events[#review_events].data.path)
      state.position = 2
      panel.render(state)
      assert.equals("plain.txt", review_events[#review_events].data.path)
      panel.close(state)
      assert.same({ name = "CodeDiffReviewClose", data = { tabpage = tab, source_tabpage = source_tab } }, review_events[#review_events])
    end)
  end)
end
