-- Small C++ tokenizer. Comments are skipped, preprocessor lines
-- (including continuation lines) become a single "pp" token. Every token
-- knows its position (0-based, end exclusive) so that text can be sliced from
-- the original and inserted at specific points.
local M = {}

---@class QtAssistToken
---@field t string   "id" | "num" | "str" | "punct" | "pp"
---@field s string   Text
---@field l integer  Start line (0-based)
---@field c integer  Start column (byte, 0-based)
---@field el integer End line
---@field ec integer End column (exclusive)

local multi = { "...", "::", "->", "&&", "||", "==", "!=", "++", "--", "+=", "-=", "*=", "/=", "|=", "&=", "^=", "%=" }

---@param lines string[]
---@return QtAssistToken[]
function M.tokenize(lines)
  local toks = {}
  local nlines = #lines
  local l, c = 1, 1 -- 1-based internally
  local in_block_comment = false
  local line_start = true -- only whitespace since the beginning of the line?

  local function push(t, s, sl, sc, el, ec)
    toks[#toks + 1] = { t = t, s = s, l = sl - 1, c = sc - 1, el = el - 1, ec = ec - 1 }
  end

  while l <= nlines do
    local line = lines[l]
    if c > #line then
      l, c = l + 1, 1
      line_start = true
    elseif in_block_comment then
      local e = line:find("*/", c, true)
      if e then
        c = e + 2
        in_block_comment = false
      else
        l, c = l + 1, 1
        line_start = true
      end
    else
      local ch = line:sub(c, c)
      if ch:match("%s") then
        c = c + 1
      elseif line:sub(c, c + 1) == "//" then
        l, c = l + 1, 1
        line_start = true
      elseif line:sub(c, c + 1) == "/*" then
        in_block_comment = true
        c = c + 2
      elseif ch == "#" and line_start then
        -- Preprocessor up to end of line including "\" continuations
        local sl, sc = l, c
        local parts = { line:sub(c) }
        while lines[l]:match("\\%s*$") and l < nlines do
          l = l + 1
          parts[#parts + 1] = lines[l]
        end
        local text = table.concat(parts, "\n"):gsub("//.*$", "")
        push("pp", text, sl, sc, l, #lines[l] + 1)
        l, c = l + 1, 1
        line_start = true
      else
        line_start = false
        local sl, sc = l, c
        -- Raw string R"delim( ... )delim"
        local raw_prefix = line:match('^[uUL8]*R"', c)
        if raw_prefix then
          local delim = line:match('^([^%(%s]*)%(', c + #raw_prefix) or ""
          local close = ")" .. delim .. '"'
          local start = c + #raw_prefix + #delim + 1
          local buf = {}
          while true do
            local e = lines[l]:find(close, start, true)
            if e then
              buf[#buf + 1] = lines[l]:sub(1, e + #close - 1)
              c = e + #close
              break
            end
            buf[#buf + 1] = lines[l]
            if l >= nlines then
              c = #lines[l] + 1
              break
            end
            l, start = l + 1, 1
          end
          push("str", table.concat(buf, "\n"), sl, sc, l, c)
        elseif ch == '"' or ch == "'" or (line:match("^[uUL8]+[\"']", c)) then
          local q_pos = line:find("[\"']", c)
          local q = line:sub(q_pos, q_pos)
          local i = q_pos + 1
          while i <= #line do
            local d = line:sub(i, i)
            if d == "\\" then
              i = i + 2
            elseif d == q then
              break
            else
              i = i + 1
            end
          end
          c = math.min(i, #line) + 1
          push("str", line:sub(sc, c - 1), sl, sc, l, c)
        elseif ch:match("[%a_]") then
          local s = line:match("^[%w_]+", c)
          c = c + #s
          push("id", s, sl, sc, l, c)
        elseif ch:match("%d") or (ch == "." and line:sub(c + 1, c + 1):match("%d")) then
          local s = line:match("^[%w_.']+", c)
          -- Exponents with sign (1e-5)
          local e = line:match("^[eEpP][+-][%d]+", c + #s - 1)
          c = c + #s
          push("num", s, sl, sc, l, c)
          if e then
            c = c - 1 + #e
          end
        else
          local found
          for _, m in ipairs(multi) do
            if line:sub(c, c + #m - 1) == m then
              found = m
              break
            end
          end
          found = found or ch
          c = c + #found
          push("punct", found, sl, sc, l, c)
        end
      end
    end
  end
  return toks
end

--- Slice text between two positions from the lines
---@param lines string[]
function M.slice(lines, sl, sc, el, ec)
  if sl == el then
    return lines[sl + 1]:sub(sc + 1, ec)
  end
  local out = { lines[sl + 1]:sub(sc + 1) }
  for i = sl + 2, el do
    out[#out + 1] = lines[i]
  end
  out[#out + 1] = lines[el + 1]:sub(1, ec)
  return table.concat(out, "\n")
end

--- Source text of tokens i..j, comments removed, whitespace collapsed
---@param toks QtAssistToken[]
function M.text(lines, toks, i, j)
  if not i or not j or j < i then
    return ""
  end
  local a, b = toks[i], toks[j]
  local s = M.slice(lines, a.l, a.c, b.el, b.ec)
  s = s:gsub("/%*.-%*/", " "):gsub("//[^\n]*", " ")
  s = s:gsub("%s+", " ")
  return vim.trim(s)
end

return M
