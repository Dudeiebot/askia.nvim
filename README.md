# asking.nvim

[![test](https://github.com/Dudeiebot/asking.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/Dudeiebot/asking.nvim/actions/workflows/test.yml)

Ask [Claude Code](https://claude.com/claude-code) about the code you're looking
at, without leaving Neovim.

Select some code — or just park the cursor inside a function — and run `:Ask`.
The answer streams into a floating window.

```
:Ask                                       the function under the cursor
:Ask why is this taking self by value?     ... with a question
:'<,'>Ask what breaks if this is nil?      ... about a visual selection
:%Ask summarise this module                ... about the whole file
```

Claude gets read-only tools, so it can grep for callers or follow a type
definition to answer properly — while being unable to touch your working tree.
You see it happen:

```
> what does shout() do to the output, and where is it defined?

⏺ Grep(function shout|shout\s*=)
⏺ Read(src/greeter.lua)
`shout()` uppercases the string and appends "!" (greeter.lua:3-5). So
`shout(out)` turns "hello <name>" into "HELLO <NAME>!", which is what gets
printed — but note `out` itself is what's returned from `greet`.
```

Inside the answer window: `<CR>` follow up · `y` yank · `q` close ·
`<C-c>` cancel.

## Requirements

- Neovim 0.10+ (`vim.system`, `vim.uv`)
- `claude` on your `$PATH`, already authenticated
- A treesitter parser for the language, if you want `:Ask` to find the
  enclosing function on its own. Without one, select a range first.

## Install

**lazy.nvim**

```lua
{
  "Dudeiebot/askia.nvim",
  cmd = { "Ask", "AskFollow", "AskCancel" },
  keys = {
    { "<leader>aa", ":Ask<CR>", mode = { "n", "x" }, silent = true, desc = "Ask Claude" },
  },
  opts = {},
}
```

**packer.nvim**

```lua
use({ "Dudeiebot/askia.nvim" })
```

**vim-plug**

```vim
Plug 'Dudeiebot/askia.nvim'
```

Calling `setup()` is optional — the commands work without it. Call it to change
a default or to have a mapping made for you.

## Configuration

```lua
require("asking").setup({
  cmd = "claude",
  model = nil,              -- "sonnet" is noticeably faster for one-shots
  allowed_tools = { "Read", "Grep", "Glob" },
  default_question = "Explain what this does and why.",
  system_prompt = "...",    -- appended to Claude's system prompt
  timeout = 180000,
  window = {
    width = 0.55,           -- fraction of the editor
    height = 0.6,
    border = "rounded",
    show_tools = true,      -- the dimmed `⏺ Grep(...)` lines
  },
  keymaps = {},             -- e.g. { ask = "<leader>aa" }
})
```

No mapping is created unless you ask for one. Full reference in
`:help asking`, and `:checkhealth asking` if something isn't working.

## How it picks the code

An explicit range always wins. Without one, it walks up the syntax tree from
the cursor until it hits a node whose type contains `function`, `method`, or
`class`. That covers Rust `function_item`, Go `function_declaration`, Python
`function_definition`, TypeScript `method_definition` and friends without
special-casing any of them.

The prompt is the file path, the line range, and the code in a fenced block —
the fence widens itself if the snippet contains backticks of its own.

## Follow-ups

Every `:Ask` starts a fresh session, but the answer window keeps its session
id, so `<CR>` (or `:AskFollow <question>`) resumes that conversation instead of
starting over. Follow-ups send only the new question — Claude still has the
snippet from the first turn.

## The honest limits

A cold call takes roughly 10–15 seconds before the first token, and streaming
only hides so much of that. It's the right shape for "explain this" and the
wrong shape for a tight back-and-forth — for that, an interactive session in a
`:terminal` split still wins.

Every `:Ask` is a real Claude Code call and is billed like one.

## Contributing

```
tests/run.sh
```

Drives the plugin headlessly against `tests/fake-claude`, a stub that replays
the event shapes `claude --output-format stream-json` actually emits. No
network, no tokens, about a second. Formatting is `stylua`.

## License

MIT
