local h = require("tests.support.e2e")
local support = require("tests.support")

for _, layout in ipairs({ "side-by-side", "inline" }) do
  describe("AI summaries / " .. layout, function()
    local repo, screen

    before_each(function()
      repo = h.repo("hunks")
      repo.replace("a.txt", 2, "working-A")
      repo.replace("b.txt", 2, "working-B")
      screen = h.screen("polling", layout, {
        ai = {
          enabled = true,
          debounce_ms = 20,
          command = { "python3", support.project_root .. "/tests/fixtures/ai/fake_codex.py", "ok" },
        },
      })
      screen:exec([[
        refresh_test.summary_calls = 0
        local provider = require('codediff.ai.provider')
        local summarize = provider.summarize
        provider.summarize = function(...)
          refresh_test.summary_calls = refresh_test.summary_calls + 1
          return summarize(...)
        end
      ]])
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

    local function ready()
      screen:await(function()
        h.assert_no_errors(screen)
        return screen:exec("return require('codediff').ai_status().status == 'ready'")
      end, "AI summaries did not become ready")
    end

    local function focus(line)
      screen:exec(
        [[
        vim.api.nvim_set_current_win(refresh_session().modified_win)
        vim.api.nvim_win_set_cursor(0, { ..., 0 })
      ]],
        { line }
      )
      screen:flush()
    end

    local function popup_text()
      return screen:exec([[
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype == 'codediff-summary' then
            return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), ' ')
          end
        end
        return ''
      ]])
    end

    local function expect_popup(text)
      screen:await(function()
        return popup_text():find(text, 1, true) ~= nil
      end, "popup did not show " .. text)
    end

    local function loading_rows()
      return screen:exec([[
        local panel = refresh_session().panel.view
        local rows = {}
        for _, line in ipairs(vim.api.nvim_buf_get_lines(panel.bufnr, 0, -1, false)) do
          if line:find(' AI', 1, true) then rows[#rows+1] = line end
        end
        return rows
      ]])
    end

    local function start_loading(scenario)
      screen:exec("require('codediff.config').options.ai.command[3] = ...", { scenario or "slow" })
      h.open(screen, repo, "CodeDiff", "a.txt")
      screen:await(function()
        return #loading_rows() == 1
      end, "selected file did not show the loading indicator")
    end

    it("animates beside the selected file and removes the indicator on completion", function()
      start_loading()
      local initial = loading_rows()[1]
      assert.is_truthy(initial:find("a.txt", 1, true))
      assert.equals("", popup_text())
      screen:await(function()
        local rows = loading_rows()
        return rows[1] and rows[1] ~= initial
      end, "spinner did not animate")
      ready()
      assert.same({}, loading_rows())
      assert.equals("", popup_text())
      h.assert_no_errors(screen)
    end)

    it("clears a cancelled indicator and stops rewriting the explorer", function()
      start_loading()
      screen:command("CodeDiffAI cancel")
      assert.same({}, loading_rows())
      local tick = screen:exec("return vim.api.nvim_buf_get_changedtick(refresh_session().panel.view.bufnr)")
      vim.wait(450)
      assert.same({}, loading_rows())
      assert.equals(tick, screen:exec("return vim.api.nvim_buf_get_changedtick(refresh_session().panel.view.bufnr)"))
      assert.equals("idle", screen:exec("return require('codediff').ai_status().status"))
    end)

    it("removes the indicator when a summary request fails", function()
      start_loading("slow_failed")
      screen:await(function()
        return screen:exec("return require('codediff').ai_status().status == 'error'")
      end, "request did not fail")
      assert.same({}, loading_rows())
      assert.equals("", popup_text())
    end)

    it("can hide the loading indicator without disabling summaries", function()
      screen:exec("require('codediff').setup({ ai = { loading_indicator = false } })")
      screen:exec("require('codediff.config').options.ai.command[3] = 'slow'")
      h.open(screen, repo, "CodeDiff", "a.txt")
      screen:await(function()
        return screen:exec("return require('codediff').ai_status().status == 'loading'")
      end, "request did not begin")
      assert.same({}, loading_rows())
      ready()
      assert.same({}, loading_rows())
    end)

    it("loads on file selection, opens only on gs, and shows the current hunk", function()
      h.open(screen, repo, "CodeDiff", "hunks.txt", "hunks.txt")
      ready()
      assert.equals(2, screen:exec("return require('codediff').ai_status().count"))
      assert.equals("", popup_text())
      focus(1)
      local source_win = screen:exec("return vim.api.nvim_get_current_win()")
      h.feed(screen, "gs")
      expect_popup("Change 1 in hunks.txt")
      assert.equals(source_win, screen:exec("return vim.api.nvim_get_current_win()"))
      local visible = false
      screen:flush()
      for row = 1, screen.height do
        if screen:text(row, 1, screen.width):find("Change 1", 1, true) then
          visible = true
        end
      end
      assert.is_true(visible, "summary must appear in the rendered UI")
      h.feed(screen, "gs")
      screen:await(function()
        return popup_text() == ""
      end, "gs did not close the popup")
      focus(12)
      h.feed(screen, "gs")
      expect_popup("Change 2 in hunks.txt")
      h.feed(screen, "k")
      screen:await(function()
        return popup_text() == ""
      end, "cursor movement did not close the popup")
    end)

    it("summarizes the newly selected file without showing the previous result", function()
      h.open(screen, repo, "CodeDiff", "a.txt")
      ready()
      h.select(screen, "b.txt", "unstaged")
      ready()
      focus(2)
      h.feed(screen, "gs")
      expect_popup("Change 1 in b.txt")
      h.assert_no_errors(screen)
    end)

    it("refreshes after edits and never opens a popup when generation completes", function()
      h.open(screen, repo, "CodeDiff", "a.txt")
      ready()
      focus(2)
      h.feed(screen, "gs")
      expect_popup("Change 1 in a.txt")
      h.feed(screen, "ccNEW_BUFFER_CHANGE<Esc>")
      h.expect_text(screen, "modified", "NEW_BUFFER_CHANGE")
      ready()
      assert.equals("", popup_text())
      h.feed(screen, "gs")
      expect_popup("Change 1 in a.txt")
    end)

    it("supports a custom mapping through the public Lua API", function()
      screen:exec("require('codediff').setup({ ai = { keymap = false } })")
      h.open(screen, repo, "CodeDiff", "a.txt")
      ready()
      focus(2)
      assert.is_false(screen:exec([[
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'n')) do
          if map.lhs == 'gs' and map.desc == 'Toggle AI change summary' then return true end
        end
        return false
      ]]))
      screen:exec("vim.keymap.set('n', '<F8>', require('codediff').toggle_summary, { buffer = true })")
      h.feed(screen, "<F8>")
      expect_popup("Change 1 in a.txt")
    end)

    it("reuses cached summaries when returning to the same comparison", function()
      h.open(screen, repo, "CodeDiff", "a.txt")
      ready()
      h.select(screen, "b.txt", "unstaged")
      ready()
      h.select(screen, "a.txt", "unstaged")
      ready()
      assert.equals(2, screen:exec("return refresh_test.summary_calls"))
      focus(2)
      h.feed(screen, "gs")
      expect_popup("Change 1 in a.txt")
    end)

    it("keeps summaries ready when the same file is selected again", function()
      h.open(screen, repo, "CodeDiff", "a.txt")
      ready()
      h.select(screen, "a.txt", "unstaged")
      assert.equals("ready", screen:exec("return require('codediff').ai_status().status"))
      assert.equals(1, screen:exec("return refresh_test.summary_calls"))
      focus(2)
      h.feed(screen, "gs")
      expect_popup("Change 1 in a.txt")
    end)

    it("can request summaries again after cancellation", function()
      h.open(screen, repo, "CodeDiff", "a.txt")
      ready()
      screen:command("CodeDiffAI cancel")
      assert.equals("idle", screen:exec("return require('codediff').ai_status().status"))
      focus(2)
      h.feed(screen, "gs")
      expect_popup("Change 1 in a.txt")
    end)

    it("disables the popup and releases its mapping when AI is turned off", function()
      h.open(screen, repo, "CodeDiff", "a.txt")
      ready()
      focus(2)
      h.feed(screen, "gs")
      expect_popup("Change 1 in a.txt")
      screen:exec("require('codediff').setup({ ai = { enabled = false } })")
      assert.equals("", popup_text())
      assert.is_false(screen:exec("return require('codediff.ui.lifecycle').owns_keymap(vim.api.nvim_get_current_tabpage(), 'gs', 'n', vim.api.nvim_get_current_buf())"))
    end)

    it("discards a late response after a file switch", function()
      screen:exec([[
        local command = require('codediff.config').options.ai.command
        command[3] = 'slow'
      ]])
      h.open(screen, repo, "CodeDiff", "a.txt")
      screen:await(function()
        return screen:exec("return require('codediff').ai_status().status == 'loading'")
      end, "first file did not begin loading")
      h.select(screen, "b.txt", "unstaged")
      ready()
      focus(2)
      h.feed(screen, "gs")
      expect_popup("Change 1 in b.txt")
      h.assert_no_errors(screen)
    end)

    it("summarizes added and deleted files and anchors deleted lines", function()
      repo.write_file("new.txt", { "new content" })
      assert.equals(0, vim.fn.delete(repo.path("gone.txt")))
      h.open(screen, repo, "CodeDiff", "new.txt", "new.txt")
      ready()
      focus(1)
      h.feed(screen, "gs")
      expect_popup("Change 1 in new.txt")
      h.select(screen, "gone.txt", "unstaged")
      ready()
      screen:exec([[
        local s = refresh_session()
        vim.api.nvim_set_current_win(s.layout == 'inline' and s.modified_win or s.original_win)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
      ]])
      screen:flush()
      h.feed(screen, "gs")
      expect_popup("Change 1 in gone.txt")
    end)
  end)
end
