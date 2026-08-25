local claude = require("asking.claude")
local config = require("asking.config")
local context = require("asking.context")
local ui = require("asking.ui")

local M = {}

local current = { job = nil, session = nil, cwd = nil }

local function cancel()
  if current.job then
    current.job:kill("sigterm")
    current.job = nil
  end
end

local function callbacks()
  return {
    on_text = ui.append_text,
    on_tool = ui.append_tool,
    on_session = function(id) current.session = id end,
    on_exit = function(err)
      current.job = nil
      ui.finish(err)
    end,
  }
end

--- Continue the conversation in the window that's already open.
function M.follow_up(question)
  if not (ui.is_open() and current.session) then
    return vim.notify("asking: no conversation to follow up on", vim.log.levels.WARN)
  end
  cancel()
  ui.append_question(question)
  current.job = claude.run(
    { prompt = question, resume = current.session, cwd = current.cwd },
    callbacks()
  )
end

--- Ask about a range, or about the function under the cursor.
---@param opts { line1: integer?, line2: integer?, question: string? }
function M.ask(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()

  -- :Ask lands here when the answer window still has focus; asking about the
  -- answer is never what was meant.
  if buf == ui.answer_buf() then
    return vim.notify(
      "asking: run :Ask from a code buffer -- <CR> follows up in this window",
      vim.log.levels.WARN
    )
  end

  local l1, l2 = opts.line1, opts.line2
  if not l1 then
    l1, l2 = context.enclosing_function(buf)
  end
  if not l1 then
    return vim.notify(
      "asking: no function under the cursor -- select a range instead",
      vim.log.levels.WARN
    )
  end
  l2 = math.min(l2, vim.api.nvim_buf_line_count(buf))

  local question = opts.question
  if not question or vim.trim(question) == "" then
    question = config.options.default_question
  end

  local prompt, label = context.build_prompt(buf, l1, l2, question)

  cancel()
  current.session = nil
  current.cwd = vim.fn.getcwd()

  ui.open({
    question = question,
    label = label,
    on_follow = M.follow_up,
    on_cancel = cancel,
  })

  current.job = claude.run({ prompt = prompt, cwd = current.cwd }, callbacks())
end

M.cancel = cancel

function M.setup(opts)
  config.setup(opts)
  local keys = config.options.keymaps or {}
  if keys.ask then
    vim.keymap.set({ "n", "x" }, keys.ask, ":Ask<CR>", {
      silent = true,
      desc = "Ask Claude about this code",
    })
  end
end

return M
