local config = require("qt-assist.config")

local M = {}

local function range_from_opts(opts)
  if opts and opts.range and opts.range > 0 then
    return opts.line1 - 1, opts.line2 - 1
  end
  local l = vim.api.nvim_win_get_cursor(0)[1] - 1
  return l, l
end

--- Aktionen an Cursor/Bereich
function M.actions(buf, l1, l2)
  buf = buf or vim.api.nvim_get_current_buf()
  if not l1 then
    l1, l2 = range_from_opts()
  end
  return require("qt-assist.actions").collect(buf, l1, l2)
end

--- Auswahlmenü (ohne LSP nutzbar). filter: Teilstring des Titels oder Lua-Pattern
function M.select(opts, filter)
  local l1, l2 = range_from_opts(opts)
  local list = M.actions(nil, l1, l2)
  if filter and filter ~= "" then
    list = vim.tbl_filter(function(a)
      return a.title:lower():find(filter:lower(), 1, true) ~= nil
    end, list)
  end
  if #list == 0 then
    vim.notify("qt-assist: keine Aktionen an dieser Stelle", vim.log.levels.INFO)
    return
  end
  if #list == 1 and filter and filter ~= "" then
    list[1].run()
    return
  end
  vim.ui.select(list, {
    prompt = "Qt Assist",
    format_item = function(a)
      return a.title
    end,
  }, function(choice)
    if choice then
      choice.run()
    end
  end)
end

--- Zwischen Header und Quelle wechseln
function M.switch()
  local buf = vim.api.nvim_get_current_buf()
  local source = require("qt-assist.source")
  local name = vim.api.nvim_buf_get_name(buf)
  local target
  if source.is_header(name) then
    target = source.find_source(buf)
  else
    target = source.find_header(buf, require("qt-assist.actions").parse_buf(buf))
  end
  if target then
    vim.cmd.edit(vim.fn.fnameescape(target))
  else
    vim.notify("qt-assist: kein Gegenstück gefunden", vim.log.levels.WARN)
  end
end

local shortcuts = {
  getset = "getter und setter",
  getter = "getter für",
  setter = "setter für",
  signal = "changed-signal",
  property = "q_property und fehlende",
  property_reset = "q_property mit reset",
  property_const = "konstante q_property",
  property_members = "fehlende member für q_property",
  define = "definition für",
  define_all = "alle fehlenden definitionen",
  move = "verschieben",
  declare = "öffentliche deklaration",
}
M.shortcuts = shortcuts

function M.setup(opts)
  config.setup(opts)
  require("qt-assist.lsp").setup()
end

return M
