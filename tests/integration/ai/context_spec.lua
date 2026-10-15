local context = require("codediff.ai.context")

describe("AI comparison capture", function()
  local session, opts

  before_each(function()
    session = {
      original_bufnr = vim.api.nvim_create_buf(false, true),
      modified_bufnr = vim.api.nvim_create_buf(false, true),
      modified = { relative = "文件 with spaces.lua" },
    }
    opts = vim.deepcopy(require("codediff.config").defaults.ai)
  end)

  after_each(function()
    for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end)

  local function set(original, modified)
    vim.api.nvim_buf_set_lines(session.original_bufnr, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, modified)
    return context.capture(session, opts)
  end

  it("captures the exact old and new code, line ranges, and file name", function()
    local snapshot = assert(set({ "start", "old", "end" }, { "start", "new", "end" }))
    local payload = vim.json.decode(snapshot.payload)
    assert.equals("文件 with spaces.lua", payload.file)
    assert.same({ "old" }, payload.changes[1].original.lines)
    assert.same({ "new" }, payload.changes[1].modified.lines)
    assert.equals(2, payload.changes[1].modified.start_line)
    assert.equals(3, payload.changes[1].modified.end_line)
    assert.same({ "start", "new", "end" }, payload.changes[1].modified.context)
  end)

  it("captures additions and deletions including deletion at end of file", function()
    local added = assert(set({ "start" }, { "start", "added" }))
    assert.same({}, added.changes[1].original.lines)
    assert.same({ "added" }, added.changes[1].modified.lines)
    local deleted = assert(set({ "start", "removed" }, { "start" }))
    assert.same({ "removed" }, deleted.changes[1].original.lines)
    assert.same({}, deleted.changes[1].modified.lines)
    assert.equals(2, deleted.changes[1].modified.start_line)
    assert.equals(2, deleted.changes[1].modified.end_line)
    session.original = { relative = "deleted.lua", absolute = "/repo/deleted.lua" }
    session.modified = { relative = "", absolute = "" }
    assert.equals("deleted.lua", assert(context.capture(session, opts)).file)
  end)

  it("rejects stale results after edits or buffer replacement", function()
    local snapshot = assert(set({ "old" }, { "new" }))
    assert.is_true(context.is_current(snapshot, session))
    vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, { "newer" })
    assert.is_false(context.is_current(snapshot, session))
    assert.is_false(context.is_current(snapshot, { original_bufnr = session.modified_bufnr, modified_bufnr = session.original_bufnr }))
  end)

  it("changes the cache key when comparison context or summary preferences change", function()
    local first = assert(set({ "old" }, { "new" }))
    opts.detail = "brief"
    local second = assert(context.capture(session, opts))
    assert.is_true(first.key ~= second.key)
    opts.detail = "detailed"
    assert.equals(first.key, assert(context.capture(session, opts)).key)
    assert.is_true(first.key ~= assert(set({ "older" }, { "new" })).key)
  end)

  it("skips unchanged files and rejects oversized inputs or conflict views", function()
    assert.equals(0, #assert(set({ "same" }, { "same" })).changes)
    opts.max_input_bytes = 10
    local result, err = set({ "old" }, { "new" })
    assert.is_nil(result)
    assert.is_truthy(err:find("too large", 1, true))
    session.merge = true
    local merged, merge_err = context.capture(session, opts)
    assert.is_nil(merged)
    assert.is_truthy(merge_err:find("merge conflict", 1, true))
  end)
end)
