local h = require("tests.support.e2e")
local support = require("tests.support")

for _, layout in ipairs({ "side-by-side", "inline" }) do
  describe("AI selected line explanations / " .. layout, function()
    local repo, screen

    before_each(function()
      repo = h.repo("hunks")
      repo.replace("a.txt", 2, "working-A")
      repo.replace("b.txt", 2, "working-B")
      screen = h.screen("polling", layout, {
        ai = {
          enabled = true,
          auto_summary = false,
          command = { "python3", support.project_root .. "/tests/fixtures/ai/fake_codex.py", "ok" },
        },
      })
      screen:exec("vim.g.mapleader = ' '")
      h.open(screen, repo, "CodeDiff", "a.txt")
      screen:exec([[
        vim.api.nvim_set_current_win(refresh_session().modified_win)
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
      ]])
      screen:flush()
    end)

    after_each(function()
      if screen then
        screen:close()
        screen = nil
      end
      if repo then
        repo.cleanup()
        repo = nil
      end
    end)

    local function result()
      return screen:exec([[
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype == 'codediff-explanation' then
            return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          end
        end
        return {}
      ]])
    end

    local function expect_result(text)
      screen:await(function()
        h.assert_no_errors(screen)
        return table.concat(result(), "\n"):find(text, 1, true) ~= nil
      end, "explanation did not contain " .. text)
    end

    it("explains a Visual line selection with source numbers and returns focus on q", function()
      local source_win = screen:exec("return vim.api.nvim_get_current_win()")
      h.feed(screen, "Vj ge")
      expect_result("2: Explain 2 in a.txt (modified): working-A")
      assert.equals(2, #result())
      assert.is_truthy(result()[2]:find("3: Explain 3", 1, true))
      assert.equals("codediff-explanation", screen:exec("return vim.bo.filetype"))
      h.feed(screen, "q")
      assert.same({}, result())
      assert.equals(source_win, screen:exec("return vim.api.nvim_get_current_win()"))
    end)

    it("captures a backwards character selection rather than old Visual marks", function()
      h.feed(screen, "vj<Esc>")
      screen:exec("vim.api.nvim_win_set_cursor(0, { 3, 3 })")
      h.feed(screen, "vk ge")
      expect_result("2: Explain 2 in a.txt (modified): working-A")
      assert.equals(2, #result())
      assert.is_truthy(result()[2]:find("3: Explain 3", 1, true))
    end)

    it("explains all source lines touched by a block selection", function()
      h.feed(screen, "<C-v>j ge")
      expect_result("2: Explain 2 in a.txt (modified): working-A")
      assert.equals(2, #result())
    end)

    it("accepts an explicit command range and explains unchanged lines", function()
      screen:command("1,3CodeDiffAI explain")
      expect_result("1: Explain 1 in a.txt")
      assert.equals(3, #result())
      h.feed(screen, "<Esc>")
      assert.same({}, result())
    end)

    it("accepts the range from the Visual command line", function()
      h.feed(screen, "Vj:CodeDiffAI explain<CR>")
      expect_result("2: Explain 2")
      assert.equals(2, #result())
      assert.is_truthy(result()[2]:find("3: Explain 3", 1, true))
    end)

    it("keeps long results scrollable and renders each explanation on its own line", function()
      screen:exec([[
        local lines = {}
        for index = 1, 80 do lines[index] = 'source line ' .. index end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      ]])
      h.feed(screen, "ggVG ge")
      expect_result("80: Explain 80 in a.txt (modified): source line 80")
      assert.equals(80, #result())
      h.feed(screen, "G")
      screen:flush()
      assert.equals(80, screen:exec("return vim.api.nvim_win_get_cursor(0)[1]"))
      local visible = false
      for row = 1, screen.height do
        if screen:text(row, 1, screen.width):find("80: Explain 80", 1, true) then
          visible = true
        end
      end
      assert.is_true(visible, "last explanation must appear in the rendered UI")
    end)

    it("does not cancel background summaries when a selection request is closed", function()
      screen:exec([[
        require('codediff.config').options.ai.command[3] = 'slow'
        require('codediff').summarize({ force = true })
      ]])
      h.feed(screen, "V ge")
      expect_result("Generating")
      h.feed(screen, "q")
      screen:await(function()
        return screen:exec("return require('codediff').ai_status().status == 'ready'")
      end, "closing the explanation interrupted the background summary")
      h.feed(screen, "gs")
      screen:await(function()
        return screen:exec("return require('codediff.ai.popup').is_open(vim.api.nvim_get_current_tabpage(), 'what')")
      end, "background summaries did not remain usable")
    end)

    it("supports remapping, disabling the default key, and the public Lua API", function()
      screen:exec("require('codediff').setup({ ai = { explain_keymap = '<F8>' } })")
      assert.is_false(screen:exec([[
        return require('codediff.ui.lifecycle').owns_keymap(vim.api.nvim_get_current_tabpage(), ' ge', 'x', vim.api.nvim_get_current_buf())
      ]]))
      h.feed(screen, "V<F8>")
      expect_result("2: Explain 2")
      h.feed(screen, "q")
      screen:exec([[
        require('codediff').setup({ ai = { explain_keymap = false } })
        vim.keymap.set('x', '<F9>', require('codediff').explain_selection, { buffer = true })
      ]])
      h.feed(screen, "V<F9>")
      expect_result("2: Explain 2")
    end)

    it("displays request errors in the result window", function()
      screen:exec("require('codediff.config').options.ai.command[3] = 'failed'")
      h.feed(screen, "V ge")
      expect_result("Usage limit reached")
      h.feed(screen, "q")
      h.assert_no_errors(screen)
    end)

    it("cancels a closed request without reopening the window", function()
      screen:exec("require('codediff.config').options.ai.command[3] = 'slow'")
      h.feed(screen, "V ge")
      expect_result("Generating")
      h.feed(screen, "q")
      vim.wait(500)
      screen:flush()
      assert.same({}, result())
      h.assert_no_errors(screen)
    end)

    it("closes stale results when another file is selected", function()
      screen:exec("require('codediff.config').options.ai.command[3] = 'slow'")
      h.feed(screen, "V ge")
      expect_result("Generating")
      h.select(screen, "b.txt", "unstaged")
      vim.wait(500)
      screen:flush()
      assert.same({}, result())
      h.assert_no_errors(screen)
    end)

    it("cancels through the public command and cleans up an externally closed window", function()
      screen:exec("require('codediff.config').options.ai.command[3] = 'slow'")
      h.feed(screen, "V ge")
      expect_result("Generating")
      screen:command("CodeDiffAI cancel")
      assert.same({}, result())
      h.feed(screen, "V ge")
      expect_result("Generating")
      screen:command("close")
      vim.wait(500)
      screen:flush()
      assert.same({}, result())
      h.assert_no_errors(screen)
    end)

    it("discards a response when the selected source buffer is edited", function()
      screen:exec("require('codediff.config').options.ai.command[3] = 'slow'")
      h.feed(screen, "V ge")
      expect_result("Generating")
      screen:exec("vim.api.nvim_buf_set_lines(refresh_session().modified_bufnr, 1, 2, false, { 'new edit' })")
      screen:await(function()
        return #result() == 0
      end, "stale explanation was not discarded")
      h.assert_no_errors(screen)
    end)

    it("releases the selection mapping and result when AI is disabled", function()
      h.feed(screen, "V ge")
      expect_result("2: Explain 2")
      screen:exec("require('codediff').setup({ ai = { enabled = false } })")
      assert.same({}, result())
      assert.is_false(screen:exec([[
        return require('codediff.ui.lifecycle').owns_keymap(vim.api.nvim_get_current_tabpage(), ' ge', 'x', vim.api.nvim_get_current_buf())
      ]]))
    end)

    if layout == "side-by-side" then
      it("uses the original pane's code and source line numbers", function()
        screen:exec([[
          vim.api.nvim_set_current_win(refresh_session().original_win)
          vim.api.nvim_win_set_cursor(0, { 2, 0 })
        ]])
        h.feed(screen, "V ge")
        expect_result("2: Explain 2 in a.txt (original):")
        assert.is_false(result()[1]:find("working-A", 1, true) ~= nil)
      end)
    end
  end)
end
