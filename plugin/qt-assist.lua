if vim.g.loaded_qt_assist then
  return
end
vim.g.loaded_qt_assist = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("qt-assist.nvim requires Neovim >= 0.10", vim.log.levels.ERROR)
  return
end

local function qa()
  return require("qt-assist")
end

vim.api.nvim_create_user_command("QtAssist", function(o)
  local key = o.fargs[1]
  local filter = key and (qa().shortcuts[key] or table.concat(o.fargs, " ")) or nil
  qa().select(o, filter)
end, {
  nargs = "*",
  range = true,
  desc = "Qt Creator refactorings (getters/setters/Q_PROPERTY/definitions)",
  complete = function()
    return vim.tbl_keys(require("qt-assist").shortcuts)
  end,
})

vim.api.nvim_create_user_command("QtAssistSwitch", function()
  qa().switch()
end, { desc = "Switch between header and source file" })
