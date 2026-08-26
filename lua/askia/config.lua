local M = {}

local defaults = {
  -- How to reach Claude Code.
  cmd = "claude",
  -- nil keeps whatever `claude` is already configured to use.
  -- "sonnet" is noticeably faster for one-shot questions.
  model = nil,
  -- Read-only tools. Claude can pull in surrounding context -- grep for
  -- callers, follow a type definition -- while being unable to edit anything.
  allowed_tools = { "Read", "Grep", "Glob" },
  -- With no question typed, open the prompt pre-filled with the default below
  -- so it can be edited before sending, instead of sending it straight away.
  -- :Ask <question> always sends immediately.
  edit_question = false,
  -- Used when :Ask is given no question.
  default_question = "Explain what this does and why.",
  -- ... and when references are attached, where "this" alone is ambiguous.
  default_question_with_references =
    "Explain what this does and why, and how each attached reference relates to it.",
  -- Appended to Claude's system prompt.
  system_prompt = "You are answering a question asked from inside Neovim, about a "
    .. "snippet the user is looking at right now. Be concise and concrete: no preamble, "
    .. "no restating the code back, no summary at the end. Prefer short paragraphs over "
    .. "bullet lists. Use the read-only tools when the answer depends on code outside "
    .. "the snippet.",
  -- Appended to the above when the question carries references, so they are
  -- treated as part of the question rather than as background.
  reference_prompt = "The user has attached code from elsewhere in the codebase, marked "
    .. "as Reference blocks. They are part of what is being asked about, not just "
    .. "background: draw on them wherever they bear on the answer, and when the question "
    .. "is open-ended, cover each of them as well as the highlighted code. Answer for all "
    .. "of them in one reply -- never stop and wait to be asked to continue. The "
    .. "attached blocks are already complete; re-read those files only if you need "
    .. "something beyond what is shown.",
  -- Milliseconds before the request is killed.
  timeout = 180000,
  -- "project": reuse one Claude session per project root, so it keeps what it
  -- already learned about the codebase and answers get faster.
  -- "question": every :Ask starts cold. Predictable, and nothing leaks between
  -- unrelated questions.
  session = "project",
  -- Minutes of inactivity after which a project's session is abandoned. A long
  -- session costs more per turn and drifts; 0 disables the expiry.
  session_ttl = 30,
  -- Remember sessions across Neovim restarts, in a small json file under
  -- stdpath("state"). Ids only -- the conversations live in ~/.claude.
  -- false keeps them in memory, dying with the process.
  session_persist = true,
  window = {
    width = 0.55,
    height = 0.6,
    -- Off by default: the window opens at the size above and stays there. Turn
    -- it on to treat that height as a ceiling the window grows into instead,
    -- so a two-line answer gets a two-line window.
    auto_height = false,
    min_height = 3,
    border = "rounded",
    -- Show `* Grep(pattern)` lines as Claude reaches for context.
    show_tools = true,
  },
  -- Where :AskTerminal puts the interactive session it hands the conversation
  -- over to: "tab", "split", "vsplit" or "float".
  terminal = { open = "tab" },
  -- No mapping is defined by default; a plugin shouldn't claim keys it wasn't
  -- given. Set `keymaps = { ask = "<leader>aa" }` to have one made for you, or
  -- map :Ask yourself.
  keymaps = {},
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", M.options, opts)
  -- tbl_deep_extend merges lists index-by-index, so a shorter list would leave
  -- the tail of the default behind. Replace these outright.
  if opts.allowed_tools then M.options.allowed_tools = opts.allowed_tools end
  if opts.keymaps == false then M.options.keymaps = {} end
end

return M
