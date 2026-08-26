local config = require("askia.config")

local M = {}

-- The field worth showing for each tool, in the order we'd rather show them.
local TOOL_FIELDS = { "pattern", "file_path", "path", "command", "query", "glob", "prompt" }

local function summarize(input)
  if type(input) ~= "table" then return "" end
  for _, key in ipairs(TOOL_FIELDS) do
    local v = input[key]
    if type(v) == "string" and v ~= "" then
      v = v:gsub("\n.*", ""):gsub("^%s+", "")
      if #v > 60 then v = v:sub(1, 59) .. "…" end
      return v
    end
  end
  return ""
end

---@param opts { prompt: string, resume: string?, cwd: string?, system_prompt: string? }
---@param cb { on_text: fun(chunk: string), on_tool: fun(line: string), on_session: fun(id: string), on_exit: fun(err: string?) }
---@return vim.SystemObj?
function M.run(opts, cb)
  local cfg = config.options

  if vim.fn.executable(cfg.cmd) == 0 then
    cb.on_exit(("`%s` is not on $PATH"):format(cfg.cmd))
    return nil
  end

  local args = {
    cfg.cmd,
    "-p", opts.prompt,
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
  }
  -- Comma-separated in a single argument: --allowedTools is variadic, and a
  -- bare list would swallow the flags that follow it.
  if cfg.allowed_tools and #cfg.allowed_tools > 0 then
    vim.list_extend(args, { "--allowedTools", table.concat(cfg.allowed_tools, ",") })
  end
  if cfg.model then vim.list_extend(args, { "--model", cfg.model }) end
  local system = opts.system_prompt or cfg.system_prompt
  if system and system ~= "" then
    vim.list_extend(args, { "--append-system-prompt", system })
  end
  if opts.resume then vim.list_extend(args, { "--resume", opts.resume }) end

  local seen_session = false

  local function handle(ev)
    if not seen_session and ev.session_id then
      seen_session = true
      cb.on_session(ev.session_id)
    end

    if ev.type == "stream_event" then
      local e = ev.event
      if e and e.type == "content_block_delta" and e.delta and e.delta.type == "text_delta" then
        cb.on_text(e.delta.text or "")
      end
    elseif ev.type == "assistant" and ev.message then
      for _, block in ipairs(ev.message.content or {}) do
        if block.type == "tool_use" then
          local detail = summarize(block.input)
          cb.on_tool(detail ~= "" and ("%s(%s)"):format(block.name, detail) or block.name)
        end
      end
    end
  end

  -- stdout arrives in arbitrary chunks; NDJSON needs whole lines.
  local pending = ""
  local function on_stdout(err, data)
    if err or not data then return end
    pending = pending .. data
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then break end
      local line = pending:sub(1, nl - 1)
      pending = pending:sub(nl + 1)
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" then
          vim.schedule(function() handle(ev) end)
        end
      end
    end
  end

  local stderr = {}

  return vim.system(args, {
    text = true,
    cwd = opts.cwd or vim.fn.getcwd(),
    timeout = cfg.timeout,
    stdout = on_stdout,
    stderr = function(_, data)
      if data then table.insert(stderr, data) end
    end,
  }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        cb.on_exit(nil)
      else
        local msg = vim.trim(table.concat(stderr))
        if msg == "" then
          msg = res.signal ~= 0 and "cancelled" or ("claude exited with code " .. res.code)
        end
        cb.on_exit(msg)
      end
    end)
  end)
end

return M
