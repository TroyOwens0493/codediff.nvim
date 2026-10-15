local support = require("tests.support")
local provider = require("codediff.ai.provider")

describe("AI Codex provider", function()
  local opts, snapshot

  before_each(function()
    opts = vim.deepcopy(require("codediff.config").defaults.ai)
    opts.command = { "python3", support.project_root .. "/tests/fixtures/ai/fake_codex.py", "ok" }
    opts.request_timeout_ms = 1000
    opts.timeout_ms = 1500
    snapshot = { changes = { { id = 1 } }, payload = vim.json.encode({ file = "example.lua", changes = { { id = 1 } } }) }
  end)

  after_each(function()
    provider.stop()
    vim.wait(20)
  end)

  local function run()
    local done, err, result
    provider.summarize(snapshot, opts, function(failure, summaries)
      done, err, result = true, failure, summaries
    end)
    assert.is_true(vim.wait(3000, function()
      return done
    end, 5))
    return err, result
  end

  it("uses managed ChatGPT auth and parses a fragmented JSONL summary", function()
    local err, result = run()
    assert.is_nil(err)
    assert.same({
      what = "Change 1 in example.lua. This explains its effect.",
      why = "Purpose of change 1 in example.lua. This explains the broader goal.",
    }, result[1])
  end)

  it("requires ChatGPT sign-in before sending code", function()
    opts.command[3] = "logged_out"
    local err = run()
    assert.is_truthy(err:find(":CodeDiffAI login", 1, true))
  end)

  it("reports a missing Codex executable", function()
    opts.command = "/codediff-test/no-such-codex"
    local err = run()
    assert.is_truthy(err:find("Cannot start Codex", 1, true), err)
  end)

  it("reports inference failures, malformed responses, and process exits", function()
    for scenario, expected in pairs({ failed = "Usage limit reached", invalid = "invalid summary", crash = "exit 7" }) do
      provider.stop()
      vim.wait(20)
      opts.command[3] = scenario
      local err = run()
      assert.is_truthy(err:find(expected, 1, true), err)
    end
  end)

  it("times out an unfinished turn", function()
    opts.command[3] = "hang"
    opts.timeout_ms = 50
    local err = run()
    assert.is_truthy(err:find("timed out", 1, true))
  end)

  it("cancels without delivering a late result", function()
    opts.command[3] = "slow"
    local called = false
    local stop = provider.summarize(snapshot, opts, function()
      called = true
    end)
    vim.wait(50)
    stop()
    vim.wait(450)
    assert.is_false(called)
  end)

  it("opens the managed login URL and reports successful sign-in", function()
    local old_open, opened, done, failure = vim.ui.open
    vim.ui.open = function(url)
      opened = url
      return {}
    end
    local ok, err = pcall(function()
      provider.login(opts, function(login_err)
        done, failure = true, login_err
      end)
      assert.is_true(vim.wait(2000, function()
        return done
      end, 5))
      assert.is_nil(failure)
      assert.equals("https://example.invalid/sign-in", opened)
    end)
    vim.ui.open = old_open
    assert(ok, err)
  end)
end)
