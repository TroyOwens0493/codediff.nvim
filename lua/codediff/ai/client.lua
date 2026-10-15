-- A small JSONL client for the local Codex app-server. Credentials stay in Codex.
local Client = {}
Client.__index = Client

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

function Client.new(opts)
  return setmetatable({ opts = opts, next_id = 0, pending = {}, listeners = {}, waiters = {}, partial = "" }, Client)
end

function Client:send(message)
  if not self.job then
    return false
  end
  return pcall(vim.fn.chansend, self.job, vim.json.encode(message) .. "\n")
end

function Client:dispatch(message)
  if message.id ~= nil and not message.method then
    local request = self.pending[message.id]
    if request then
      self.pending[message.id] = nil
      close_timer(request.timer)
      request.callback(message.error and message.error.message or nil, message.result)
    end
  elseif message.id ~= nil then
    -- This integration only summarizes supplied text. Never approve tool actions.
    if message.method:match("requestApproval$") then
      self:send({ id = message.id, result = { decision = "decline" } })
    else
      self:send({ id = message.id, error = { code = -32601, message = "CodeDiff AI does not support interactive tools" } })
    end
  elseif message.method then
    for _, listener in ipairs(vim.list_slice(self.listeners)) do
      listener(message.method, message.params or {})
    end
  end
end

function Client:request(method, params, callback)
  if not self.job then
    callback("Codex is not running.")
    return
  end
  self.next_id = self.next_id + 1
  local id = self.next_id
  local timer = (vim.uv or vim.loop).new_timer()
  self.pending[id] = { callback = callback, timer = timer }
  timer:start(
    self.opts.request_timeout_ms,
    0,
    vim.schedule_wrap(function()
      local request = self.pending[id]
      if request then
        self.pending[id] = nil
        close_timer(timer)
        request.callback("Codex request timed out: " .. method)
      end
    end)
  )
  if not self:send({ id = id, method = method, params = params }) then
    self.pending[id] = nil
    close_timer(timer)
    callback("Could not write to Codex.")
  end
end

function Client:listen(callback)
  self.listeners[#self.listeners + 1] = callback
  return function()
    for index, listener in ipairs(self.listeners) do
      if listener == callback then
        table.remove(self.listeners, index)
        break
      end
    end
  end
end

function Client:fail(reason)
  self.ready = false
  local pending = self.pending
  self.pending = {}
  for _, request in pairs(pending) do
    close_timer(request.timer)
    request.callback(reason)
  end
  for _, listener in ipairs(vim.list_slice(self.listeners)) do
    listener("client/stopped", { error = reason })
  end
end

function Client:start(callback)
  if self.ready then
    callback(nil, self)
    return
  end
  self.waiters[#self.waiters + 1] = callback
  if self.job then
    return
  end
  local command = type(self.opts.command) == "table" and vim.deepcopy(self.opts.command) or { self.opts.command }
  vim.list_extend(command, { "app-server", "--listen", "stdio://" })
  local cwd = vim.fn.stdpath("cache") .. "/codediff-ai"
  vim.fn.mkdir(cwd, "p")
  self.partial = ""
  local function initialized(err)
    self.ready = not err
    local waiters = self.waiters
    self.waiters = {}
    for _, waiter in ipairs(waiters) do
      waiter(err, not err and self or nil)
    end
  end
  local started, job = pcall(vim.fn.jobstart, command, {
    cwd = cwd,
    on_stdout = function(_, data)
      for index, part in ipairs(data) do
        if index == 1 then
          self.partial = self.partial .. part
        else
          local line = self.partial
          self.partial = part
          if line ~= "" then
            local ok, message = pcall(vim.json.decode, line, { luanil = { object = true } })
            if ok and type(message) == "table" then
              self:dispatch(message)
            end
          end
        end
      end
    end,
    on_stderr = function() end, -- Do not retain logs that might contain account details.
    on_exit = function(_, code)
      self.job = nil
      self:fail("Codex stopped (exit " .. code .. ").")
      if #self.waiters > 0 then
        initialized("Codex stopped before it was ready.")
      end
    end,
  })
  if not started or job <= 0 then
    initialized("Cannot start Codex. Install the Codex CLI and check ai.command.")
    return
  end
  self.job = job
  self:request("initialize", { clientInfo = { name = "codediff_nvim", title = "CodeDiff", version = "0.1.0" } }, function(err)
    if err then
      initialized(err)
      self:stop()
      return
    end
    self:send({ method = "initialized" })
    initialized()
  end)
end

function Client:stop()
  if self.job then
    pcall(vim.fn.jobstop, self.job)
  end
end

return Client
