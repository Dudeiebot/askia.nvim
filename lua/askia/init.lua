local claude = require("askia.claude")
local config = require("askia.config")
local context = require("askia.context")
local refs = require("askia.refs")
local store = require("askia.store")
local ui = require("askia.ui")

local M = {}

--- A checkout is the natural unit for a session, so these win outright.
local VCS_MARKERS = { ".git", ".hg", ".svn" }

--- Failing that, the nearest thing that looks like a project. Order here is
--- deliberately not significant: the deepest match wins, so a Rust crate inside
--- a JS monorepo keys on the crate rather than on whichever manifest happens to
--- be listed first.
local PROJECT_MARKERS = {
  "package.json",
  "Cargo.toml",
  "go.mod",
  "pyproject.toml",
  "pom.xml",
  "build.gradle",
  "Gemfile",
  "composer.json",
  "Makefile",
}

--- Session ids keyed by project root, mirroring askia.store's file. Loaded on
--- first use; nil means "not read yet", which is not the same as empty.
local sessions = nil

local current = { job = nil, session = nil, root = nil }

local function cancel()
  if current.job then
    current.job:kill("sigterm")
    current.job = nil
  end
end

local function ttl_seconds()
  return (config.options.session_ttl or 0) * 60
end

local function known()
  if not sessions then
    sessions = config.options.session_persist and store.read() or {}
  end
  return sessions
end

--- Record (entry) or forget (nil) a project's session, on disk and in memory.
local function keep(root, entry)
  known()[root] = entry
  if config.options.session_persist then
    sessions = store.update(root, entry, ttl_seconds())
  end
end

--- The directory a session is keyed on.
---
--- vim.fs.root() resolves a list of markers by list order rather than by
--- distance, so each marker is asked about separately and the deepest answer
--- taken. Every candidate is an ancestor of the same file, so the longest path
--- is the nearest one.
---@return string
function M.project_root(buf)
  buf = buf or vim.api.nvim_get_current_buf()

  local ok, repo = pcall(vim.fs.root, buf, VCS_MARKERS)
  if ok and repo then return repo end

  local nearest
  for _, marker in ipairs(PROJECT_MARKERS) do
    local found_ok, found = pcall(vim.fs.root, buf, marker)
    if found_ok and found and (not nearest or #found > #nearest) then
      nearest = found
    end
  end
  if nearest then return nearest end

  -- Nothing project-shaped anywhere above the file. Its own directory is a
  -- truer key than the current directory, which may be another project
  -- entirely.
  local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
  if name ~= "" then return vim.fs.dirname(name) end
  return vim.fn.getcwd()
end

local project_root = M.project_root

--- The project being asked about. The answer window is a nameless scratch
--- buffer, so asking it for a root would land on the current directory
--- instead of the project the question came from.
local function active_root()
  local buf = vim.api.nvim_get_current_buf()
  if buf == ui.answer_buf() and current.root then
    return current.root
  end
  return project_root(buf)
end

--- The project's session id, if we have one that hasn't gone stale.
local function reusable_session(root)
  if config.options.session ~= "project" then return nil end
  local entry = known()[root]
  if not entry then return nil end

  local ttl = ttl_seconds()
  if ttl > 0 and (store.now() - entry.used) > ttl then
    keep(root, nil)
    return nil
  end
  return entry.id
end

local callbacks

---@param run { prompt: string, cwd: string, root: string, resume: string? }
callbacks = function(run)
  local got_text = false
  return {
    on_text = function(chunk)
      got_text = true
      ui.append_text(chunk)
    end,
    on_tool = ui.append_tool,
    on_session = function(id)
      current.session = id
      keep(run.root, { id = id, used = store.now() })
    end,
    on_exit = function(err)
      current.job = nil

      -- A stored id can go stale -- pruned by claude, or from another machine.
      -- Retry once from cold rather than failing the question.
      if err and run.resume and not got_text then
        keep(run.root, nil)
        ui.append_tool("session expired, starting fresh")
        local retry = { prompt = run.prompt, cwd = run.cwd, root = run.root }
        current.job = claude.run(retry, callbacks(retry))
        return
      end

      ui.finish(err)
      -- Only worth mentioning if the answer is hidden rather than discarded:
      -- after a quit there is nothing for :AskToggle to bring back.
      if not err and not ui.is_open() and ui.answer_buf() then
        vim.notify("askia: answer ready (:AskToggle)", vim.log.levels.INFO)
      end
    end,
  }
end

--- Continue the conversation in the answer window.
function M.follow_up(question)
  if not current.session then
    return vim.notify("askia: no conversation to follow up on", vim.log.levels.WARN)
  end
  cancel()
  ui.append_question(question)
  local run = {
    prompt = question,
    cwd = current.root or vim.fn.getcwd(),
    root = current.root,
    resume = current.session,
  }
  current.job = claude.run(run, callbacks(run))
end

--- The lines a command is about: an explicit range, else the enclosing
--- function. Returns nil after telling the user why.
---@return integer?, integer?
local function target_lines(buf, l1, l2)
  if not l1 then
    l1, l2 = context.enclosing_function(buf)
  end
  if not l1 then
    vim.notify(
      "askia: no function under the cursor -- select a range instead",
      vim.log.levels.WARN
    )
    return nil
  end
  return l1, math.min(l2, vim.api.nvim_buf_line_count(buf))
end

--- Attach the function under the cursor (or a range) to the next question.
---@param opts { line1: integer?, line2: integer? }
function M.add_reference(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  if buf == ui.answer_buf() then
    return vim.notify("askia: nothing to attach from the answer window", vim.log.levels.WARN)
  end

  local l1, l2 = target_lines(buf, opts.line1, opts.line2)
  if not l1 then return end

  local item = refs.add(buf, l1, l2)
  local total = refs.count()
  vim.notify(("askia: attached %s (%d-%d) -- %d reference%s"):format(
    item.path, l1, l2, total, total == 1 and "" or "s"
  ))
end

function M.clear_references()
  local had = refs.count()
  refs.clear()
  vim.notify(("askia: %d reference%s cleared"):format(had, had == 1 and "" or "s"))
end

--- Ask about a range, or about the function under the cursor.
---@param opts { line1: integer?, line2: integer?, question: string?, fresh: boolean? }
function M.ask(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()

  -- :Ask lands here when the answer window still has focus; asking about the
  -- answer is never what was meant.
  if buf == ui.answer_buf() then
    return vim.notify(
      "askia: run :Ask from a code buffer -- <CR> follows up in this window",
      vim.log.levels.WARN
    )
  end

  local l1, l2 = target_lines(buf, opts.line1, opts.line2)
  if not l1 then return end

  -- References stay attached until :AskClear, so a set can serve several
  -- questions.
  local references = refs.resolve()

  local question = opts.question
  local typed = question ~= nil and vim.trim(question) ~= ""
  if not typed then
    -- Spelled out rather than `cond and a or b`: if the refs-aware default were
    -- ever nil, that idiom would quietly fall through to the plain one.
    if #references > 0 and config.options.default_question_with_references then
      question = config.options.default_question_with_references
    else
      question = config.options.default_question
    end
  end

  local prompt, label = context.build_prompt(buf, l1, l2, question, references)
  local system_prompt = #references > 0
      and (config.options.system_prompt .. " " .. config.options.reference_prompt)
    or nil
  local root = project_root(buf)
  local resume = not opts.fresh and reusable_session(root) or nil

  cancel()
  current.session = resume
  current.root = root

  -- Fired either straight away, or when a composed question is submitted.
  local function send(asked)
    local body = context.build_prompt(buf, l1, l2, asked, references)
    ui.append_question(asked)
    local run = {
      prompt = body,
      cwd = root,
      root = root,
      resume = resume,
      system_prompt = system_prompt,
    }
    current.job = claude.run(run, callbacks(run))
  end

  -- With no question typed and edit_question on, open the prompt pre-filled so
  -- it can be edited first; the same prompt line then serves follow-ups.
  local compose = config.options.edit_question and not typed
  local composing = compose

  ui.open({
    question = not compose and question or nil,
    draft = compose and question or nil,
    label = resume and (label .. " · continued") or label,
    on_follow = function(asked)
      if composing then
        composing = false
        send(asked)
      else
        M.follow_up(asked)
      end
    end,
    on_cancel = cancel,
    on_quit = M.quit,
    on_terminal = M.escalate,
  })

  if compose then return end

  -- cwd is the project root, not Neovim's, so Read and Grep see the whole repo.
  local run = {
    prompt = prompt,
    cwd = root,
    root = root,
    resume = resume,
    -- Only when there is something attached, so ordinary questions keep the
    -- shorter system prompt.
    system_prompt = system_prompt,
  }
  current.job = claude.run(run, callbacks(run))
end

--- The command that continues this conversation interactively.
---@return string[]
function M.terminal_command(id)
  local cmd = { config.options.cmd, "--resume", id }
  if config.options.model then
    vim.list_extend(cmd, { "--model", config.options.model })
  end
  return cmd
end

local function open_terminal_window()
  local how = (config.options.terminal or {}).open or "tab"

  if how == "float" then
    local cols = vim.o.columns
    local rows = vim.o.lines - vim.o.cmdheight - 1
    local width, height = math.floor(cols * 0.85), math.floor(rows * 0.85)
    vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.max(0, math.floor((rows - height) / 2)),
      col = math.floor((cols - width) / 2),
      border = config.options.window.border,
      title = " claude · interactive ",
      title_pos = "left",
    })
  elseif how == "split" then
    vim.cmd("split")
    vim.cmd("enew")
  elseif how == "vsplit" then
    vim.cmd("vsplit")
    vim.cmd("enew")
  else
    vim.cmd("tabnew")
  end
end

--- Hand this project's conversation to a real interactive Claude session.
---
--- The float is a one-shot shape; this is the door out of it. The session id
--- is the same one :Ask has been resuming, so everything Claude already knows
--- about the code carries over.
function M.escalate()
  local root = active_root()
  local id = current.session or (known()[root] and known()[root].id)
  if not id then
    return vim.notify(
      "askia: no session to hand over -- ask something first",
      vim.log.levels.WARN
    )
  end

  -- One transcript, one writer: a request still in flight would be resumed
  -- from two places at once.
  cancel()
  ui.hide()

  open_terminal_window()
  local buf = vim.api.nvim_get_current_buf()
  vim.fn.jobstart(M.terminal_command(id), {
    term = true,
    cwd = root,
    on_exit = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end)
    end,
  })
  vim.cmd("startinsert")
end

local function ago(seconds)
  if seconds < 60 then return ("%ds ago"):format(math.floor(seconds)) end
  if seconds < 3600 then return ("%dm ago"):format(math.floor(seconds / 60)) end
  return ("%.1fh ago"):format(seconds / 3600)
end

--- What askia currently knows about this project's session.
---@return string[] the reported lines, for tests
function M.info()
  local root = active_root()
  local entry = known()[root]
  local ttl = ttl_seconds()

  local lines = { "askia", ("  root      %s"):format(vim.fn.fnamemodify(root, ":~")) }
  if entry then
    local age = store.now() - entry.used
    table.insert(lines, ("  session   %s"):format(entry.id))
    table.insert(lines, ("  age       %s%s"):format(
      ago(age),
      (ttl > 0 and age > ttl) and "   (expired, next :Ask starts cold)" or ""
    ))
  else
    table.insert(lines, "  session   none yet -- the next :Ask starts cold")
  end

  table.insert(lines, ("  mode      %s  ·  ttl %s  ·  %s"):format(
    config.options.session,
    ttl > 0 and (tostring(config.options.session_ttl) .. "m") or "none",
    config.options.session_persist and "persisted" or "memory only"
  ))

  if refs.count() > 0 then
    table.insert(lines, ("  refs      %d attached"):format(refs.count()))
    for _, line in ipairs(refs.summary()) do
      table.insert(lines, "            " .. line)
    end
  end

  if config.options.session_persist then
    local stat = store.stat()
    table.insert(lines, ("  store     %s"):format(vim.fn.fnamemodify(store.path(), ":~")))
    table.insert(lines, ("            %d project%s, %d bytes"):format(
      stat.projects, stat.projects == 1 and "" or "s", stat.bytes
    ))
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  return lines
end

--- Close the answer window and discard it, stopping anything still running.
function M.quit()
  cancel()
  ui.close()
end

--- Put the answer window away, or bring the last one back.
function M.toggle()
  if not ui.toggle() then
    vim.notify("askia: nothing to come back to yet", vim.log.levels.WARN)
  end
end

--- Forget the session for the current project, so the next :Ask starts cold.
function M.reset_session()
  local root = active_root()
  keep(root, nil)
  current.session = nil
  vim.notify("askia: session reset for " .. vim.fn.fnamemodify(root, ":~"))
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
  if keys.toggle then
    vim.keymap.set("n", keys.toggle, M.toggle, { desc = "Toggle the Claude answer window" })
  end
end

return M
