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
  -- Used when :Ask is given no question.
  default_question = "Explain what this does and why.",
  -- Appended to Claude's system prompt.
  system_prompt = "You are answering a question asked from inside Neovim, about a "
    .. "snippet the user is looking at right now. Be concise and concrete: no preamble, "
    .. "no restating the code back, no summary at the end. Prefer short paragraphs over "
    .. "bullet lists. Use the read-only tools when the answer depends on code outside "
    .. "the snippet.",
  -- Milliseconds before the request is killed.
  timeout = 180000,
  window = {
    width = 0.55,
    height = 0.6,
    border = "rounded",
    -- Show `* Grep(pattern)` lines as Claude reaches for context.
    show_tools = true,
  },
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
