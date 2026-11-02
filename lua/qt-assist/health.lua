local M = {}

function M.check()
  local h = vim.health
  local config = require("qt-assist.config").options
  local source = require("qt-assist.source")

  h.start("qt-assist")
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim >= 0.10")
  else
    h.error("Neovim >= 0.10 benötigt")
  end

  if config.lsp.enabled then
    h.ok("Code-Actions über In-Process-LSP '" .. config.lsp.name .. "' für: " .. table.concat(config.lsp.filetypes, ", "))
  else
    h.info("LSP-Integration deaktiviert – Aktionen über :QtAssist")
  end

  h.start("qt-assist: Integrationen")
  if pcall(require, "cmake-tools") then
    h.ok("cmake-tools.nvim gefunden (Build-Verzeichnis → compile_commands.json)")
  else
    h.info("cmake-tools.nvim nicht installiert (optional)")
  end
  if pcall(require, "qmake-tools") then
    h.ok("qmake-tools.nvim gefunden (Build-Verzeichnis → compile_commands.json)")
  else
    h.info("qmake-tools.nvim nicht installiert (optional)")
  end
  local get = vim.lsp.get_clients or vim.lsp.get_active_clients
  if #get({ name = "clangd" }) > 0 then
    h.ok("clangd läuft (switchSourceHeader wird genutzt)")
  else
    h.info("clangd läuft gerade nicht (optional, für die Header↔Quelle-Zuordnung)")
  end

  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" and (source.is_header(name) or source.is_source(name)) then
    h.start("qt-assist: aktuelle Datei")
    local ccs = source.compile_commands_files(buf, vim.fs.normalize(vim.fn.fnamemodify(name, ":p")))
    if #ccs > 0 then
      for _, c in ipairs(ccs) do
        h.ok("compile_commands.json: " .. c)
      end
    else
      h.warn("keine compile_commands.json gefunden")
    end
    if source.is_header(name) then
      local s, how = source.find_source(buf)
      if s then
        h.ok("Quelldatei: " .. s .. " (" .. how .. ")")
      else
        h.warn("keine Quelldatei gefunden", { "source.search_dirs anpassen oder source.create_missing nutzen" })
      end
    end
  end
end

return M
