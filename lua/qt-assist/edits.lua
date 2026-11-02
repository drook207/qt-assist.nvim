-- Collected text changes across multiple buffers, applied backwards so that
-- positions do not shift relative to each other.
local config = require("qt-assist.config")

local M = {}

local uv = vim.uv or vim.loop

--- Load a buffer for a file (creating it if needed)
function M.load(path)
  local buf = vim.fn.bufadd(path)
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  vim.bo[buf].buflisted = true
  return buf
end

function M.lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Contents of a file: from the buffer if loaded, otherwise from disk
function M.file_lines(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return M.lines(buf), buf
  end
  if uv.fs_stat(path) then
    return vim.fn.readfile(path), nil
  end
  return {}, nil
end

--- Determine the indentation unit of a buffer/file
function M.indent_unit(buf, lines)
  local o = config.options.indent
  if type(o) == "number" then
    return string.rep(" ", o)
  elseif type(o) == "string" then
    return o
  end
  lines = lines or (buf and M.lines(buf)) or {}
  local tabs, min_spaces = 0, nil
  local counts = {}
  for _, l in ipairs(lines) do
    local ws = l:match("^(%s+)%S")
    if ws then
      if ws:find("\t") then
        tabs = tabs + 1
      elseif not l:match("^%s+%*") then -- ignore comment continuations
        local n = #ws
        counts[n] = (counts[n] or 0) + 1
        if n >= 2 and (not min_spaces or n < min_spaces) then
          min_spaces = n
        end
      end
    end
  end
  if tabs > 0 and tabs >= vim.tbl_count(counts) then
    return "\t"
  end
  if min_spaces then
    return string.rep(" ", min_spaces)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local bo = vim.bo[buf]
    if not bo.expandtab and vim.api.nvim_buf_line_count(buf) > 1 then
      return "\t"
    end
    local sw = bo.shiftwidth
    if sw == 0 then
      sw = bo.tabstop
    end
    if sw > 0 and sw <= 8 and bo.expandtab then
      return string.rep(" ", sw)
    end
  end
  return "    "
end

-- ---------------------------------------------------------------------------
-- Batch
-- ---------------------------------------------------------------------------

local Batch = {}
Batch.__index = Batch

function M.batch()
  return setmetatable({ edits = {}, seq = 0, bufs = {}, order = {} }, Batch)
end

function Batch:_add(buf, e)
  self.seq = self.seq + 1
  e.seq = self.seq
  if not self.edits[buf] then
    self.edits[buf] = {}
    self.order[#self.order + 1] = buf
  end
  table.insert(self.edits[buf], e)
end

--- Insert lines before line `row` (0-based); row = line count → append
function Batch:insert_lines(buf, row, lines)
  self:_add(buf, { row = row, col = 0, end_row = row, end_col = 0, lines = lines, kind = "lines" })
end

--- Replace text (0-based, end exclusive)
function Batch:replace(buf, sr, sc, er, ec, lines)
  self:_add(buf, { row = sr, col = sc, end_row = er, end_col = ec, lines = lines, kind = "text" })
end

function Batch:empty()
  return #self.order == 0
end

--- Apply. Returns the positions (buffer, line) of the first insertion per buffer.
function Batch:apply()
  local first = {}
  for _, buf in ipairs(self.order) do
    local list = self.edits[buf]
    table.sort(list, function(a, b)
      if a.row ~= b.row then
        return a.row > b.row
      end
      if a.col ~= b.col then
        return a.col > b.col
      end
      return a.seq > b.seq
    end)
    local count = vim.api.nvim_buf_line_count(buf)
    -- empty buffer: one empty line
    local empty = count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
    for _, e in ipairs(list) do
      if e.kind == "lines" then
        local row = e.row
        if empty then
          vim.api.nvim_buf_set_lines(buf, 0, 1, false, e.lines)
          empty = false
        else
          if row > vim.api.nvim_buf_line_count(buf) then
            row = vim.api.nvim_buf_line_count(buf)
          end
          vim.api.nvim_buf_set_lines(buf, row, row, false, e.lines)
        end
      else
        vim.api.nvim_buf_set_text(buf, e.row, e.col, e.end_row, e.end_col, e.lines)
      end
    end
    -- remember the first (smallest) line
    local minrow
    for _, e in ipairs(list) do
      if not minrow or e.row < minrow then
        minrow = e.row
      end
    end
    first[buf] = minrow
  end
  if config.options.auto_save then
    for _, buf in ipairs(self.order) do
      if vim.bo[buf].modified then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("silent write")
        end)
      end
    end
  end
  return first
end

M.Batch = Batch

return M
