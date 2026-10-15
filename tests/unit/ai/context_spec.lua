local context = require("codediff.ai.context")

describe("AI summary validation", function()
  local snapshot = { changes = { {}, {} } }

  it("matches summaries by id instead of response order and removes control characters", function()
    local result = assert(context.decode(vim.json.encode({ summaries = { { id = 2, summary = "Second\nchange." }, { id = 1, summary = " First change. " } } }), snapshot))
    assert.equals("First change.", result[1])
    assert.equals("Second change.", result[2])
  end)

  it("rejects missing, repeated, unknown, or fractional change ids", function()
    for _, entries in ipairs({
      { { id = 1, summary = "one" } },
      { { id = 1, summary = "one" }, { id = 1, summary = "again" } },
      { { id = 1, summary = "one" }, { id = 3, summary = "unknown" } },
      { { id = 1, summary = "one" }, { id = 1.5, summary = "fraction" } },
    }) do
      local result, err = context.decode(vim.json.encode({ summaries = entries }), snapshot)
      assert.is_nil(result)
      assert.is_truthy(err)
    end
  end)

  it("rejects malformed, empty, or oversized text", function()
    for _, text in ipairs({
      "not JSON",
      '{"summaries":null}',
      '{"summaries":{}}',
      vim.json.encode({ summaries = { { id = 1, summary = " " }, { id = 2, summary = "ok" } } }),
      vim.json.encode({ summaries = { { id = 1, summary = string.rep("a", 2001) }, { id = 2, summary = "ok" } } }),
    }) do
      assert.is_nil(context.decode(text, snapshot))
    end
  end)
end)
