local M = {}

function M.check()
  local h = vim.health
  local config = require("qt-assist.config").options
  local source = require("qt-assist.source")

  h.start("qt-assist")
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim >= 0.10")
  else
    h.error("Neovim >= 0.10 required")
  end

  if config.lsp.enabled then
    h.ok("Code actions via in-process LSP '" .. config.lsp.name .. "' for: " .. table.concat(config.lsp.filetypes, ", "))
  else
    h.info("LSP integration disabled – actions via :QtAssist")
  end

  h.start("qt-assist: integrations")
  if pcall(require, "cmake-tools") then
    h.ok("cmake-tools.nvim found (build directory → compile_commands.json)")
  else
    h.info("cmake-tools.nvim not installed (optional)")
  end
  if pcall(require, "qmake-tools") then
    h.ok("qmake-tools.nvim found (build directory → compile_commands.json)")
  else
    h.info("qmake-tools.nvim not installed (optional)")
  end
  local get = vim.lsp.get_clients or vim.lsp.get_active_clients
  if #get({ name = "clangd" }) > 0 then
    h.ok("clangd is running (switchSourceHeader is used)")
  else
    h.info("clangd is not running right now (optional, for header↔source mapping)")
  end

  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" and (source.is_header(name) or source.is_source(name)) then
    h.start("qt-assist: current file")
    local ccs = source.compile_commands_files(buf, vim.fs.normalize(vim.fn.fnamemodify(name, ":p")))
    if #ccs > 0 then
      for _, c in ipairs(ccs) do
        h.ok("compile_commands.json: " .. c)
      end
    else
      h.warn("no compile_commands.json found")
    end
    if source.is_header(name) then
      local s, how = source.find_source(buf)
      if s then
        h.ok("source file: " .. s .. " (" .. how .. ")")
      else
        h.warn("no source file found", { "adjust source.search_dirs or use source.create_missing" })
      end
    end
  end
end

return M
