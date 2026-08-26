local config = require("askia.config")

local M = {}

function M.check()
  local health = vim.health
  health.start("askia")

  local cmd = config.options.cmd
  if vim.fn.executable(cmd) == 1 then
    local out = vim.system({ cmd, "--version" }, { text = true }):wait()
    health.ok(("`%s` found: %s"):format(cmd, vim.trim(out.stdout or "")))
  else
    health.error(("`%s` is not on $PATH"):format(cmd))
  end

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("neovim " .. tostring(vim.version()))
  else
    health.error("neovim 0.10+ required (vim.system, vim.uv)")
  end

  -- A health check runs in its own buffer, so there is no "current filetype"
  -- to test here. Report what parsers exist and let the reader match that
  -- against the languages they work in.
  local seen = {}
  for _, path in ipairs(vim.api.nvim_get_runtime_file("parser/*", true)) do
    seen[vim.fn.fnamemodify(path, ":t:r")] = true
  end
  local names = vim.tbl_keys(seen)
  table.sort(names)

  if #names == 0 then
    health.warn("no treesitter parsers installed", {
      ":Ask can still be given a range; it just cannot find the enclosing function",
    })
  else
    local shown = names
    if #names > 12 then
      shown = vim.list_slice(names, 1, 12)
      shown[#shown + 1] = ("… (%d more)"):format(#names - 12)
    end
    health.ok(("%d treesitter parsers: %s"):format(#names, table.concat(shown, ", ")))
    health.info("cursor-mode :Ask needs a parser for the language you are in")
  end
end

return M
