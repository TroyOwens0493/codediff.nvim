local context = require("codediff.ai.context")

describe("AI summary validation", function()
  local snapshot = { changes = { {}, {} } }

  it("matches summaries by id instead of response order and removes control characters", function()
    local result = assert(
      context.decode(
        vim.json.encode({ summaries = { { id = 2, what = "Second\nchange.", why = "Likely\tto fix a bug." }, { id = 1, what = " First change. ", why = " Purpose unknown. " } } }),
        snapshot
      )
    )
    assert.same({ what = "First change.", why = "Purpose unknown." }, result[1])
    assert.same({ what = "Second change.", why = "Likely to fix a bug." }, result[2])
  end)

  it("rejects missing, repeated, unknown, or fractional change ids", function()
    for _, entries in ipairs({
      { { id = 1, what = "one", why = "reason" } },
      { { id = 1, what = "one", why = "reason" }, { id = 1, what = "again", why = "reason" } },
      { { id = 1, what = "one", why = "reason" }, { id = 3, what = "unknown", why = "reason" } },
      { { id = 1, what = "one", why = "reason" }, { id = 1.5, what = "fraction", why = "reason" } },
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
    }) do
      assert.is_nil(context.decode(text, snapshot))
    end
  end)

  it("requires valid text for both what and why on every change", function()
    for _, kind in ipairs({ "what", "why" }) do
      for _, invalid in ipairs({ false, 1, " ", string.rep("a", 2001) }) do
        local entries = { { id = 1, what = "change", why = "reason" }, { id = 2, what = "change", why = "reason" } }
        entries[1][kind] = invalid
        assert.is_nil(context.decode(vim.json.encode({ summaries = entries }), snapshot))
      end
      local entries = { { id = 1, what = "change", why = "reason" }, { id = 2, what = "change", why = "reason" } }
      entries[2][kind] = nil
      assert.is_nil(context.decode(vim.json.encode({ summaries = entries }), snapshot))
    end
  end)
end)
