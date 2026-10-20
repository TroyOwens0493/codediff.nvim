local format = require("codediff.review.format")

describe("Guided review validation", function()
  local snapshot, guide
  before_each(function()
    snapshot = {
      files = {
        {
          file = "a.lua",
          group = "unstaged",
          changes = {
            {
              id = 1,
              original = { start_line = 2, end_line = 4, lines = { "old two", "old three" } },
              modified = { start_line = 3, end_line = 5, lines = { "new three", "new four" } },
            },
          },
        },
        { file = "a.lua", group = "staged", changes = {} },
      },
    }
    guide = {
      steps = {
        {
          title = " Change the contract. ",
          summary = "The new contract connects the components.",
          attention = "",
          excerpts = { { file_id = 1, change_id = 1, side = "modified", start_line = 3, end_line = 4, caption = "The contract" } },
          files = {},
          notes = { { excerpt = 1, line = 4, text = "Required by the caller." } },
          questions = { "Why change the contract?" },
        },
      },
    }
  end)

  it("uses real source lines and accounts for omitted files and staged duplicates", function()
    local steps = assert(format.decode(vim.json.encode(guide), snapshot))
    assert.equals("Change the contract.", steps[1].title)
    assert.same({ "3 │ new three", "4 │ new four" }, format.excerpt_lines(snapshot, steps[1].excerpts[1]))
    assert.equals("Other changed files", steps[2].title)
    assert.same({ 2 }, steps[2].files)
    guide.steps[1].excerpts[1].side = "original"
    guide.steps[1].excerpts[1].start_line, guide.steps[1].excerpts[1].end_line = 2, 3
    guide.steps[1].notes[1].line = 3
    steps = assert(format.decode(vim.json.encode(guide), snapshot))
    assert.same({ "2 │ old two", "3 │ old three" }, format.excerpt_lines(snapshot, steps[1].excerpts[1]))
  end)

  it("rejects invented files, sides, changes, and lines rather than showing unverified code", function()
    for field, invalid in pairs({ file_id = 999, change_id = 2, side = "new", start_line = 2, end_line = 5 }) do
      local bad = vim.deepcopy(guide)
      bad.steps[1].excerpts[1][field] = invalid
      local result, err = format.decode(vim.json.encode(bad), snapshot)
      assert.is_nil(result, field)
      assert.is_truthy(err)
    end
  end)

  it("rejects notes outside their excerpt, empty sides, and oversized excerpts", function()
    guide.steps[1].notes[1].line = 2
    assert.is_nil(format.decode(vim.json.encode(guide), snapshot))
    guide.steps[1].notes = {}
    snapshot.files[1].changes[1].modified.end_line = 3
    assert.is_nil(format.decode(vim.json.encode(guide), snapshot))
    snapshot.files[1].changes[1].modified.end_line = 100
    guide.steps[1].excerpts[1].end_line = 28
    assert.is_nil(format.decode(vim.json.encode(guide), snapshot))
  end)

  it("rejects malformed structures and missing explanations", function()
    for _, encoded in ipairs({ "bad JSON", "{}", '{"steps":null}', '{"steps":{}}', '{"steps":[]}' }) do
      assert.is_nil(format.decode(encoded, snapshot))
    end
    for _, key in ipairs({ "summary", "title", "excerpts", "files", "notes", "questions" }) do
      local bad = vim.deepcopy(guide)
      bad.steps[1][key] = false
      assert.is_nil(format.decode(vim.json.encode(bad), snapshot))
    end
  end)
end)

describe("Guided review stop changes", function()
  local function change(old, new, line)
    return {
      original = { start_line = line, end_line = line + 1, lines = { old }, context_start_line = line - 1, context = { "context before", old, "context after" } },
      modified = { start_line = line, end_line = line + 1, lines = { new }, context_start_line = line - 1, context = { "context before", new, "context after" } },
    }
  end
  local function snapshot()
    return {
      files = {
        { file = "contract.lua", group = "unstaged", changes = { change("old contract", "new contract", 2), change("old other feature", "new other feature", 20) } },
        { file = "caller.lua", group = "unstaged", changes = { change("old call", "new call", 7) } },
        { file = "renamed.lua", group = "staged", changes = {} },
      },
    }
  end

  it("excludes other changes in the same file and preserves source line locations", function()
    local display = require("codediff.review.changes").build(snapshot(), { excerpts = { { file_id = 1, change_id = 1 } }, files = {} })
    local text = table.concat(display.modified, "\n")
    assert.is_truthy(text:find("new contract", 1, true))
    assert.is_truthy(text:find("context before", 1, true))
    assert.is_nil(text:find("other feature", 1, true))
    assert.is_nil(text:find("caller.lua", 1, true))
    assert.equals(2, display.locations.modified[display.blocks[1].rows.modified].line)
    assert.equals("contract.lua", display.locations.modified[display.blocks[1].rows.modified].path)
  end)

  it("shows related blocks from multiple files and deduplicates repeated excerpts", function()
    local display = require("codediff.review.changes").build(snapshot(), {
      excerpts = { { file_id = 1, change_id = 1 }, { file_id = 1, change_id = 1 } },
      files = { 2, 3 },
    })
    assert.equals(3, #display.blocks)
    local text = table.concat(display.modified, "\n")
    assert.is_truthy(text:find("new contract", 1, true))
    assert.is_truthy(text:find("new call", 1, true))
    assert.is_truthy(text:find("renamed.lua [staged]", 1, true))
    assert.is_nil(text:find("new other feature", 1, true))
  end)

  it("does not include differing neighboring context from another change", function()
    local input = snapshot()
    input.files[1].changes[1].modified.context[1] = "unrelated modified line"
    local display = require("codediff.review.changes").build(input, { excerpts = { { file_id = 1, change_id = 1 } }, files = {} })
    assert.is_nil(table.concat(display.modified, "\n"):find("unrelated", 1, true))
  end)
end)
