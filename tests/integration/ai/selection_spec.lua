local selection = require("codediff.ai.selection")

describe("AI selected line context", function()
  local session, opts

  before_each(function()
    session = {
      original_bufnr = vim.api.nvim_create_buf(false, true),
      modified_bufnr = vim.api.nvim_create_buf(false, true),
      original = { relative = "old name.lua" },
      modified = { relative = "new name.lua" },
      original_revision = "HEAD",
      modified_revision = "WORKING",
    }
    opts = vim.deepcopy(require("codediff.config").defaults.ai)
    opts.context_lines = 1
    vim.api.nvim_buf_set_lines(session.original_bufnr, 0, -1, false, { "before", "old", "", "after" })
    vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, { "before", "new", "", "after" })
  end)

  after_each(function()
    for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end)

  it("captures reversed ranges, blank lines, and nearby source without renumbering", function()
    local snapshot = assert(selection.capture(session, session.modified_bufnr, 3, 2, opts))
    local payload = vim.json.decode(snapshot.payload)
    assert.equals("new name.lua", payload.file)
    assert.equals("modified", payload.side)
    assert.equals("WORKING", payload.revision)
    assert.same({ { line = 2, text = "new" }, { line = 3, text = "" } }, payload.lines)
    assert.same(payload.lines, snapshot.lines)
    assert.equals(vim.bo[session.modified_bufnr].tabstop, snapshot.tabstop)
    assert.equals(vim.bo[session.modified_bufnr].filetype, snapshot.filetype)
    assert.equals(1, payload.context_start_line)
    assert.same({ "before", "new", "", "after" }, payload.context)
    assert.is_truthy(selection.prompt(snapshot):find("ASD-STE100", 1, true))
  end)

  it("uses the original file and revision when selecting the old pane", function()
    local snapshot = assert(selection.capture(session, session.original_bufnr, 2, 2, opts))
    local payload = vim.json.decode(snapshot.payload)
    assert.equals("old name.lua", payload.file)
    assert.equals("original", payload.side)
    assert.equals("HEAD", payload.revision)
    assert.same({ { line = 2, text = "old" } }, payload.lines)
  end)

  it("rejects non-source buffers, invalid ranges, oversized input, and conflicts", function()
    assert.is_nil(selection.capture(session, 0, 1, 1, opts))
    assert.is_nil(selection.capture(session, session.modified_bufnr, 0, 2, opts))
    assert.is_nil(selection.capture(session, session.modified_bufnr, 1, 5, opts))
    opts.max_input_bytes = 1
    local _, err = selection.capture(session, session.modified_bufnr, 1, 1, opts)
    assert.is_truthy(err:find("too large", 1, true))
    session.merge = true
    assert.is_nil(selection.capture(session, session.modified_bufnr, 1, 1, opts))
  end)

  it("discards a snapshot after source edits, a revision change, or a file switch", function()
    local snapshot = assert(selection.capture(session, session.modified_bufnr, 2, 3, opts))
    assert.is_true(selection.is_current(snapshot, session))
    session.modified_revision = "OTHER"
    assert.is_false(selection.is_current(snapshot, session))
    session.modified_revision = "WORKING"
    vim.api.nvim_buf_set_lines(session.modified_bufnr, 1, 2, false, { "edited" })
    assert.is_false(selection.is_current(snapshot, session))
    assert.is_false(selection.is_current(snapshot, nil))
  end)

  it("sorts and formats exactly one explanation per source line", function()
    local snapshot = { first_line = 2, last_line = 3 }
    local result = assert(selection.decode(
      vim.json.encode({ explanations = {
        { line = 3, explanation = " Blank\nline. " },
        { line = 2, explanation = "Read the value." },
      } }),
      snapshot
    ))
    assert.same({ "Read the value.", "Blank line." }, result)
  end)

  it("rejects missing, duplicate, noninteger, unselected, and empty explanations", function()
    local snapshot = { first_line = 2, last_line = 3 }
    for _, entries in ipairs({
      { { line = 2, explanation = "Only one." } },
      { { line = 2, explanation = "First." }, { line = 2, explanation = "Duplicate." } },
      { { line = 2, explanation = "First." }, { line = 3.5, explanation = "Fraction." } },
      { { line = 1, explanation = "Outside." }, { line = 3, explanation = "Last." } },
      { { line = 2, explanation = "First." }, { line = 3, explanation = " \n " } },
    }) do
      assert.is_nil(selection.decode(vim.json.encode({ explanations = entries }), snapshot))
    end
    assert.is_nil(selection.decode("invalid JSON", snapshot))
  end)
end)
