local repository = require("tests.support.repository")
local context = require("codediff.ai.context")
local comparison = require("codediff.ai.comparison")

describe("AI whole comparison context", function()
  local repo, session, opts, base, target

  before_each(function()
    repo = repository.new({
      key = "ai-comparison",
      build = function(seed)
        seed.write_file("a.lua", { "old A" })
        seed.write_file("b.lua", { "old B" })
        local first = seed.commit("Initial code")
        seed.write_file("a.lua", { "new A" })
        seed.write_file("b.lua", { "new B" })
        local second = seed.commit("Connect A to B\n\nBoth components must use the new interface.")
        return { base = first, target = second }
      end,
    })
    base, target = repo.seed.base, repo.seed.target
    session = {
      git_root = repo.dir,
      original_revision = base,
      modified_revision = target,
      original_bufnr = vim.api.nvim_create_buf(false, true),
      modified_bufnr = vim.api.nvim_create_buf(false, true),
      modified = { relative = "a.lua" },
      panel = {
        name = "explorer",
        data = {
          git_root = repo.dir,
          base_revision = base,
          target_revision = target,
          current_selection = { path = "a.lua", group = "unstaged" },
          status_result = { unstaged = { { path = "a.lua", status = "M" }, { path = "b.lua", status = "M" } }, staged = {} },
        },
      },
    }
    vim.api.nvim_buf_set_lines(session.original_bufnr, 0, -1, false, { "old A" })
    vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, { "new A in buffer" })
    opts = vim.deepcopy(require("codediff.config").defaults.ai)
  end)

  after_each(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if buf == session.original_bufnr or buf == session.modified_bufnr or name:sub(1, #repo.dir) == repo.dir then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    repo.cleanup()
  end)

  local function capture()
    local done, err, result
    comparison.capture(session, assert(context.capture(session, opts)), opts, function(failure, value)
      done, err, result = true, failure, value
    end)
    assert.is_true(vim.wait(3000, function()
      return done
    end, 5))
    return err, result
  end

  it("includes other files in the reviewed range, commit bodies, and exact selected buffer text", function()
    local err, snapshot = capture()
    assert.is_nil(err)
    local data = vim.json.decode(snapshot.payload)
    assert.equals(2, #data.comparison.files)
    assert.same({ "new A in buffer" }, data.comparison.files[1].changes[1].modified.lines)
    assert.equals("b.lua", data.comparison.files[2].file)
    assert.same({ "old B" }, data.comparison.files[2].changes[1].original.lines)
    assert.same({ "new B" }, data.comparison.files[2].changes[1].modified.lines)
    assert.is_truthy(data.comparison.commit_messages:find("Both components must use the new interface.", 1, true))
    assert.is_nil(data.comparison.commit_messages:find("Initial code", 1, true))
  end)

  it("uses the index for unstaged changes and invalidates the cache for other file edits", function()
    session.panel.data.base_revision, session.panel.data.target_revision = nil, nil
    session.modified_revision = nil
    repo.write_file("b.lua", { "staged B" })
    repo.command({ "add", "b.lua" })
    repo.write_file("b.lua", { "working B" })
    session.panel.data.status_result.staged = { { path = "b.lua", status = "M" } }
    session.panel.view = { visible_groups = { staged = false } }
    local err, first = capture()
    assert.is_nil(err)
    local data = vim.json.decode(first.payload)
    assert.same({ "staged B" }, data.comparison.files[2].changes[1].original.lines)
    assert.same({ "working B" }, data.comparison.files[2].changes[1].modified.lines)
    assert.equals("", data.comparison.commit_messages)
    repo.write_file("b.lua", { "later B" })
    local next_err, second = capture()
    assert.is_nil(next_err)
    assert.is_true(first.key ~= second.key)
  end)

  it("includes unsaved edits in another working file and detects stale results", function()
    session.panel.data.base_revision, session.panel.data.target_revision = nil, nil
    session.modified_revision = nil
    local buf = vim.fn.bufadd(repo.path("b.lua"))
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved B" })
    local err, snapshot = capture()
    assert.is_nil(err)
    assert.same({ "unsaved B" }, vim.json.decode(snapshot.payload).comparison.files[2].changes[1].modified.lines)
    assert.is_true(context.is_current(snapshot, session))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "newer unsaved B" })
    assert.is_false(context.is_current(snapshot, session))
  end)

  it("respects the file list and hidden staged group, including untracked files", function()
    session.panel.data.base_revision, session.panel.data.target_revision = nil, nil
    session.modified_revision = nil
    repo.write_file("new.lua", { "new untracked code" })
    session.panel.view = { visible_groups = { staged = false } }
    session.panel.data.status_result = {
      unstaged = { { path = "a.lua", status = "M" }, { path = "new.lua", status = "??" } },
      staged = { { path = "b.lua", status = "M" } },
    }
    local err, snapshot = capture()
    assert.is_nil(err)
    local files = vim.json.decode(snapshot.payload).comparison.files
    assert.equals(2, #files)
    assert.equals("new.lua", files[2].file)
    assert.same({ "new untracked code" }, files[2].changes[1].modified.lines)
  end)

  it("rejects an oversized full comparison even when the selected file fits", function()
    repo.write_file("b.lua", { string.rep("x", 3000) })
    session.panel.data.target_revision = nil
    opts.max_input_bytes = 2000
    local err = capture()
    assert.is_truthy(err:find("comparison is too large", 1, true))
  end)

  it("collects the entire selected history commit when its files are not expanded", function()
    session.panel = {
      name = "history",
      data = { git_root = repo.dir, current_commit = target, files = {}, parents = { [target] = { base } }, opts = {} },
    }
    local err, snapshot = capture()
    assert.is_nil(err)
    local data = vim.json.decode(snapshot.payload)
    assert.equals(2, #data.comparison.files)
    assert.equals("b.lua", data.comparison.files[2].file)
    assert.is_truthy(data.comparison.commit_messages:find("Connect A to B", 1, true))
  end)

  it("cancels before delivering comparison context", function()
    local called = false
    local stop = comparison.capture(session, assert(context.capture(session, opts)), opts, function()
      called = true
    end)
    stop()
    vim.wait(30)
    assert.is_false(called)
  end)
end)
