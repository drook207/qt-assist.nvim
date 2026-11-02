-- Text-Erzeugung und Einfügepunkte in Header (Klasse) und Quelldatei.
local config = require("qt-assist.config")
local parser = require("qt-assist.parser")
local lexer = require("qt-assist.lexer")
local edits = require("qt-assist.edits")
local naming = require("qt-assist.naming")

local M = {}

local function leading_ws(line)
  return (line or ""):match("^(%s*)")
end

local function is_blank(line)
  return line == nil or line:match("^%s*$") ~= nil
end

local function strip_templates(s)
  local prev
  repeat
    prev = s
    s = s:gsub("<[^<>]*>", "")
  until s == prev
  return vim.trim(s)
end

--- Pfad (Namespaces + Klassenkette) einer Klasse
function M.class_path(cls)
  local path = {}
  for _, n in ipairs(cls.ns) do
    path[#path + 1] = n
  end
  for _, n in ipairs(cls.chain) do
    path[#path + 1] = n
  end
  return path
end

--- Template-Parameternamen aus "template <typename T, int N = 3>" → "T, N"
local function template_args(tpl)
  local inner = tpl:match("<(.*)>")
  if not inner then
    return ""
  end
  local names = {}
  local depth, cur = 0, ""
  local parts = {}
  for ch in inner:gmatch(".") do
    if ch == "<" or ch == "(" then
      depth = depth + 1
    elseif ch == ">" or ch == ")" then
      depth = depth - 1
    end
    if ch == "," and depth == 0 then
      parts[#parts + 1] = cur
      cur = ""
    else
      cur = cur .. ch
    end
  end
  parts[#parts + 1] = cur
  for _, p in ipairs(parts) do
    p = p:gsub("=.*$", "")
    local name = p:match("([%w_]+)%s*$")
    local variadic = p:find("...", 1, true)
    if name then
      names[#names + 1] = name .. (variadic and "..." or "")
    end
  end
  return table.concat(names, ", ")
end

--- Template-Präfix ohne Default-Argumente
local function template_decl(tpl)
  local inner = tpl:match("<(.*)>") or ""
  local parts, depth, cur = {}, 0, ""
  for ch in inner:gmatch(".") do
    if ch == "<" or ch == "(" then
      depth = depth + 1
    elseif ch == ">" or ch == ")" then
      depth = depth - 1
    end
    if ch == "," and depth == 0 then
      parts[#parts + 1] = cur
      cur = ""
    else
      cur = cur .. ch
    end
  end
  parts[#parts + 1] = cur
  for i, p in ipairs(parts) do
    parts[i] = vim.trim((p:gsub("%s*=.*$", "")))
  end
  return "template <" .. table.concat(parts, ", ") .. ">"
end

--- Ist die Klasse (oder eine äußere) ein Template?
function M.is_template_class(cls)
  local c = cls
  while c do
    if c.template then
      return true
    end
    c = c.outer
  end
  return false
end

--- Qualifizierer der Klasse für Out-of-Class-Definitionen ("Outer::Inner<T>::")
--- und die nötigen template-Zeilen
function M.class_qualifier(cls)
  local chain, tpls = {}, {}
  local list = {}
  local c = cls
  while c do
    table.insert(list, 1, c)
    c = c.outer
  end
  for _, k in ipairs(list) do
    if k.template then
      chain[#chain + 1] = k.name .. "<" .. template_args(k.template) .. ">"
      tpls[#tpls + 1] = template_decl(k.template)
    else
      chain[#chain + 1] = k.name
    end
  end
  return chain, tpls
end

--- Verschachtelte Typen der Klasse im Rückgabetyp qualifizieren
local function qualify_nested(ret, cls, chain_str)
  if not cls or ret == "" then
    return ret
  end
  local out = ret:gsub("()([%a_][%w_]*)", function(pos, word)
    if cls.nested_types[word] then
      local before = ret:sub(1, pos - 1)
      if not before:match("::%s*$") then
        return chain_str .. "::" .. word
      end
    end
    return nil
  end)
  return out
end

--- "T" + "name" ohne doppelte Leerzeichen
local function join_ret(ret, rest)
  if ret == "" then
    return rest
  end
  ret = ret:gsub("([^%s%*&])([%*&]+)$", "%1 %2")
  if ret:match("[%*&]$") then
    return ret .. rest
  end
  return ret .. " " .. rest
end

--- Parameterliste ohne Default-Argumente
function M.params_without_defaults(d)
  local out = {}
  for _, prm in ipairs(d.params) do
    out[#out + 1] = prm.text
  end
  return table.concat(out, ", ")
end

--- Signatur einer Out-of-Class-Definition
---@param d table Funktionsdeklaration aus dem Parser
---@param cls table Klasse
---@param qualifier string z. B. "Person::" oder "app::model::Person::"
function M.definition_signature(d, cls, qualifier)
  local chain = M.class_qualifier(cls)
  local ret = d.ret or ""
  if not d.trailing_ret then
    ret = qualify_nested(ret, cls, qualifier:gsub("::$", ""))
  end
  local trailing = table.concat(d.trailing or {}, " ")
  local sig = join_ret(ret, qualifier .. d.name .. "(" .. M.params_without_defaults(d) .. ")")
  if trailing ~= "" then
    sig = sig .. " " .. trailing
  end
  if d.trailing_ret then
    sig = sig .. " -> " .. d.trailing_ret
  end
  _ = chain
  return sig
end

--- Funktion als Zeilen (Signatur + Rumpf)
---@param sig string
---@param body string[] Rumpfzeilen ohne Einrückung (eine Ebene wird ergänzt)
---@param base string Basiseinrückung
---@param unit string Einrückungseinheit
function M.function_lines(sig, body, base, unit, prefix_lines)
  local out = {}
  for _, l in ipairs(prefix_lines or {}) do
    out[#out + 1] = base .. l
  end
  if config.options.brace_on_new_line then
    out[#out + 1] = base .. sig
    out[#out + 1] = base .. "{"
  else
    out[#out + 1] = base .. sig .. " {"
  end
  for _, l in ipairs(body) do
    if l == "" then
      out[#out + 1] = ""
    else
      out[#out + 1] = base .. unit .. l:gsub("{indent}", unit)
    end
  end
  out[#out + 1] = base .. "}"
  return out
end

-- ---------------------------------------------------------------------------
-- Einfügen in die Klasse (Header)
-- ---------------------------------------------------------------------------

local ClassInserter = {}
ClassInserter.__index = ClassInserter

---@param p table Parse-Ergebnis
---@param cls table Klasse
---@param buf integer
---@param batch table
function M.class_inserter(p, cls, buf, batch)
  local self = setmetatable({ p = p, cls = cls, buf = buf, batch = batch, groups = {}, order = {}, after = {} }, ClassInserter)
  self.unit = edits.indent_unit(buf, p.lines)
  local class_indent = leading_ws(p.lines[cls.start_line + 1])
  self.class_indent = class_indent
  -- Einrückung der Member: erster Member/Makro, der am Zeilenanfang steht
  local member_indent
  local cands = {}
  for _, m in ipairs(cls.members) do
    cands[#cands + 1] = m.start_line
  end
  for _, m in ipairs(cls.macros) do
    cands[#cands + 1] = m.line
  end
  table.sort(cands)
  for _, l in ipairs(cands) do
    if l > cls.open_line then
      member_indent = leading_ws(p.lines[l + 1])
      break
    end
  end
  self.member_indent = member_indent or (class_indent .. self.unit)
  local label_indent
  for _, s in ipairs(cls.sections) do
    label_indent = leading_ws(p.lines[s.line + 1])
    break
  end
  self.label_indent = label_indent or class_indent
  return self
end

--- Passenden vorhandenen Abschnitt suchen
---@param spec table {access=, kind=}
function ClassInserter:find_section(spec)
  local found
  for _, s in ipairs(self.cls.sections) do
    if s.kind == spec.kind and (spec.kind == "signals" or s.access == spec.access) then
      found = s
    end
  end
  return found
end

local function spec_key(spec)
  return spec.kind .. ":" .. (spec.access or "")
end

--- Zeilen (bereits eingerückt) einem Abschnitt hinzufügen
function ClassInserter:add(spec, lines)
  local key = spec_key(spec)
  local g = self.groups[key]
  if not g then
    g = { spec = spec, items = {} }
    self.groups[key] = g
    self.order[#self.order + 1] = key
  end
  g.items[#g.items + 1] = lines
end

--- Einfache Deklaration (eine Zeile) mit Member-Einrückung
function ClassInserter:add_decl(spec, text)
  self:add(spec, { self.member_indent .. text })
end

--- Zeilen hinter der Klasse (z. B. Inline-Definitionen) einfügen
function ClassInserter:add_after_class(lines)
  self.after[#self.after + 1] = lines
end

function ClassInserter:label(spec)
  if spec.kind == "signals" then
    return self.label_indent .. config.options.signal.keyword .. ":"
  elseif spec.kind == "slots" then
    return self.label_indent .. spec.access .. " slots:"
  end
  return self.label_indent .. spec.access .. ":"
end

--- Q_PROPERTY einfügen
function ClassInserter:add_property(text)
  self.props = self.props or {}
  self.props[#self.props + 1] = self.member_indent .. text
end

function ClassInserter:ensure_qobject(macro)
  if not self.cls.qobject then
    self.need_qobject = macro or "Q_OBJECT"
  end
end

function ClassInserter:finish()
  local cls, p, b, buf = self.cls, self.p, self.batch, self.buf
  -- Q_OBJECT ergänzen
  if self.need_qobject then
    b:insert_lines(buf, cls.open_line + 1, { self.member_indent .. self.need_qobject })
  end
  -- Q_PROPERTY
  if self.props and #self.props > 0 then
    local row
    if config.options.property.placement == "private" then
      for _, l in ipairs(self.props) do
        self:add({ access = "private", kind = "normal" }, { l })
      end
    else
      if #cls.properties > 0 then
        row = cls.properties[#cls.properties].end_line + 1
      elseif cls.qobject then
        row = cls.qobject.end_line + 1
      else
        row = cls.open_line + 1
      end
      b:insert_lines(buf, row, self.props)
    end
  end
  -- Abschnitte
  local close_line = cls.close_line
  local close_tok = p.toks[cls.close]
  local brace_first = vim.trim(p.lines[close_line + 1]:sub(1, close_tok.c)) == ""
  for _, key in ipairs(self.order) do
    local g = self.groups[key]
    local lines = {}
    for _, item in ipairs(g.items) do
      vim.list_extend(lines, item)
    end
    local sec = self:find_section(g.spec)
    local implicit_members = false
    for _, m in ipairs(cls.members) do
      if m.section == nil then
        implicit_members = true
      end
    end
    local implicit = not sec and g.spec.kind == "normal" and g.spec.access == cls.default_access
        and (#cls.sections == 0 or implicit_members)
    if sec then
      b:insert_lines(buf, (sec.last_line or sec.line) + 1, lines)
    elseif implicit then
      b:insert_lines(buf, (cls.implicit_last or cls.open_line) + 1, lines)
    else
      local block = {}
      local prev = p.lines[close_line] -- Zeile vor der schließenden Klammer
      if not is_blank(prev) and close_line - 1 > cls.open_line then
        block[#block + 1] = ""
      end
      block[#block + 1] = self:label(g.spec)
      vim.list_extend(block, lines)
      if brace_first then
        b:insert_lines(buf, close_line, block)
      else
        table.insert(block, 1, "")
        block[#block + 1] = self.class_indent
        b:replace(buf, close_line, close_tok.c, close_line, close_tok.c, block)
      end
    end
  end
  for i, lines in ipairs(self.after) do
    local block = { "" }
    vim.list_extend(block, lines)
    if i == #self.after and not is_blank(p.lines[cls.end_line + 2]) then
      block[#block + 1] = ""
    end
    b:insert_lines(buf, cls.end_line + 1, block)
  end
end

-- ---------------------------------------------------------------------------
-- Quelldatei: Index der vorhandenen Definitionen
-- ---------------------------------------------------------------------------

local function path_key(path)
  return table.concat(path, "::")
end

--- Ermittelt für eine Out-of-Class-Definition die möglichen Klassenpfade
local function def_class_paths(sp, f)
  local q = {}
  for _, part in ipairs(f.qualifier) do
    q[#q + 1] = strip_templates(part)
  end
  if #q == 0 then
    return {}
  end
  local res = {}
  local base = vim.deepcopy(f.ns)
  vim.list_extend(base, q)
  res[#res + 1] = base
  -- using namespace auf Dateiebene oder im umgebenden Namespace
  local usings = vim.deepcopy(sp.usings)
  local s = f.scope
  while s do
    for _, u in ipairs(s.usings or {}) do
      usings[#usings + 1] = u
    end
    s = s.parent
  end
  for _, u in ipairs(usings) do
    local path = vim.deepcopy(u)
    vim.list_extend(path, q)
    res[#res + 1] = path
  end
  -- Qualifizierer relativ zu einem äußeren Namespace (namespace a { b::C::f() })
  for i = #f.ns - 1, 0, -1 do
    local path = vim.list_slice(f.ns, 1, i)
    vim.list_extend(path, q)
    res[#res + 1] = path
  end
  return res
end

M.def_class_paths = def_class_paths

--- Signaturschlüssel, Klassen-Qualifizierer in Parametertypen entfernt
local function sig_key(f, class_names)
  local types = {}
  for _, prm in ipairs(f.params) do
    local t = prm.type
    for _, n in ipairs(class_names or {}) do
      t = t:gsub("[%w_:]*%f[%w_]" .. vim.pesc(n) .. "::", "")
    end
    types[#types + 1] = parser.normalize_type(t)
  end
  return f.name .. "(" .. table.concat(types, ",") .. ")" .. (f.is_const and "const" or "")
end
M.sig_key = sig_key

--- Index: Klassenpfad → Liste von Definitionen
function M.source_index(sp)
  local idx = {}
  for _, f in ipairs(sp.functions) do
    if not f.class and (f.has_body or f.defaulted or f.deleted) and #f.qualifier > 0 then
      for _, path in ipairs(def_class_paths(sp, f)) do
        local key = path_key(path)
        idx[key] = idx[key] or {}
        table.insert(idx[key], f)
      end
    end
  end
  return idx
end

--- Definition einer Deklaration in der Quelle suchen
function M.find_definition(index, cls, d)
  local list = index[path_key(M.class_path(cls))]
  if not list then
    return nil
  end
  local key = sig_key(d, cls.chain)
  for _, f in ipairs(list) do
    if sig_key(f, cls.chain) == key then
      return f
    end
  end
  -- Nur über Name und Parameteranzahl (z. B. abweichende Typ-Schreibweise)
  local cands = {}
  for _, f in ipairs(list) do
    if f.name == d.name and #f.params == #d.params and f.is_const == d.is_const then
      cands[#cands + 1] = f
    end
  end
  if #cands == 1 then
    return cands[1]
  end
end

--- Ist eine Funktionsdeklaration irgendwo definiert (inline, Header, Quelle)?
function M.is_defined(d, cls, header_index, source_index)
  if d.has_body or d.pure or d.defaulted or d.deleted then
    return true
  end
  if header_index and M.find_definition(header_index, cls, d) then
    return true
  end
  if source_index and M.find_definition(source_index, cls, d) then
    return true
  end
  return false
end

--- Funktionen, für die eine Definition erzeugt werden kann
function M.needs_definition(d)
  if d.kind ~= "function" or d.has_body or d.pure or d.defaulted or d.deleted then
    return false
  end
  if d.section and d.section.kind == "signals" then
    return false
  end
  if d.specs.friend then
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Einfügen in die Quelldatei
-- ---------------------------------------------------------------------------

local SourceInserter = {}
SourceInserter.__index = SourceInserter

---@param sp table Parse-Ergebnis der Quelle
---@param buf integer
---@param batch table
---@param header_path string|nil für #include in neuen Dateien
function M.source_inserter(sp, buf, batch, opts)
  opts = opts or {}
  local self = setmetatable({
    sp = sp, buf = buf, batch = batch, index = M.source_index(sp),
    points = {}, new_blocks = {}, need_using = {}, opts = opts,
  }, SourceInserter)
  self.unit = edits.indent_unit(buf, sp.lines)
  return self
end

--- Einfügepunkt-Gruppe (gleiche Zeile) holen
function SourceInserter:point(row, mode)
  local key = row .. ":" .. mode
  local pt = self.points[key]
  if not pt then
    pt = { row = row, mode = mode, items = {}, seq = vim.tbl_count(self.points) }
    self.points[key] = pt
  end
  return pt
end

--- Tiefster Namespace-Block, dessen Pfad ein Präfix von path ist
function SourceInserter:deepest_block(path)
  local best, best_len = nil, 0
  for _, ns in ipairs(self.sp.namespaces) do
    local np = ns.ns
    if #np <= #path and #np > best_len then
      local ok = true
      for i = 1, #np do
        if np[i] ~= path[i] then
          ok = false
          break
        end
      end
      if ok then
        best, best_len = ns, #np
      elseif #np == #path then
        -- nichts
      end
    end
  end
  return best, best_len
end

local function file_using_covers(sp, path)
  local key = path_key(path)
  for _, u in ipairs(sp.usings) do
    if path_key(u) == key then
      return true
    end
  end
  return false
end

--- Definition hinzufügen
---@param cls table Klasse aus dem Header
---@param make fun(qualifier: string): string[] Zeilen ohne Basiseinrückung
---@param anchor_decl table|nil Deklaration im Header (für die Reihenfolge)
---@param prev_decls table[]|nil Deklarationen davor (nächste zuerst)
---@param next_decls table[]|nil Deklarationen danach
function SourceInserter:add(cls, make, prev_decls, next_decls)
  local sp = self.sp
  local chain = M.class_qualifier(cls)
  local chain_str = table.concat(chain, "::") .. "::"
  local list = self.index[path_key(M.class_path(cls))] or {}

  local function qualifier_like(f)
    -- Schreibweise des Nachbarn übernehmen (z. B. "app::model::Person::")
    local q = table.concat(f.qualifier, "::")
    local plain = strip_templates(q)
    local chain_plain = strip_templates(table.concat(chain, "::"))
    if plain:sub(-#chain_plain) == chain_plain then
      return q:sub(1, #q - #chain_plain) .. table.concat(chain, "::") .. "::"
    end
    return chain_str
  end

  -- 1. Nachbar mit Definition
  for _, d in ipairs(prev_decls or {}) do
    local f = M.find_definition(self.index, cls, d)
    if f then
      local pt = self:point(f.end_line + 1, "after")
      pt.items[#pt.items + 1] = make(qualifier_like(f))
      return
    end
  end
  for _, d in ipairs(next_decls or {}) do
    local f = M.find_definition(self.index, cls, d)
    if f then
      local pt = self:point(f.start_line, "before")
      pt.items[#pt.items + 1] = make(qualifier_like(f))
      return
    end
  end
  -- 2. letzte Definition der Klasse
  if #list > 0 then
    local last = list[1]
    for _, f in ipairs(list) do
      if f.end_line > last.end_line then
        last = f
      end
    end
    local pt = self:point(last.end_line + 1, "after")
    pt.items[#pt.items + 1] = make(qualifier_like(last))
    return
  end
  -- 3. Namespaces
  local path = {}
  for _, n in ipairs(cls.ns) do
    if n ~= "" then
      path[#path + 1] = n
    end
  end
  if #path == 0 then
    local pt = self:point(#sp.lines, "eof")
    pt.items[#pt.items + 1] = make(chain_str)
    return
  end
  local block, depth = self:deepest_block(path)
  if block and depth == #path then
    local pt = self:point(block.close_line, "close")
    pt.items[#pt.items + 1] = make(chain_str)
    return
  end
  if file_using_covers(sp, path) then
    local pt = self:point(#sp.lines, "eof")
    pt.items[#pt.items + 1] = make(chain_str)
    return
  end
  local missing = vim.list_slice(path, depth + 1)
  local mode = config.options.missing_namespace
  if mode == "qualify" then
    local q = table.concat(missing, "::") .. "::" .. chain_str
    local pt = block and self:point(block.close_line, "close") or self:point(#sp.lines, "eof")
    pt.items[#pt.items + 1] = make(q)
  elseif mode == "using" then
    -- using-Direktive ergänzen, Definition auf Dateiebene ans Ende
    self.need_using[path_key(path)] = path
    local pt = self:point(#sp.lines, "eof")
    pt.items[#pt.items + 1] = make(chain_str)
  else
    -- neue Namespace-Blöcke anlegen (gesammelt pro Container + Pfad)
    local key = (block and tostring(block.open) or "file") .. "|" .. path_key(missing)
    local nb = self.new_blocks[key]
    if not nb then
      nb = { block = block, missing = missing, items = {} }
      self.new_blocks[key] = nb
      local pt = block and self:point(block.close_line, "close") or self:point(#sp.lines, "eof")
      pt.items[#pt.items + 1] = nb -- Platzhalter, wird in finish aufgelöst
    end
    nb.items[#nb.items + 1] = make(chain_str)
  end
end

--- Namespace-Block um Zeilen legen
local function namespace_block(missing, items)
  local o = config.options
  local open, close = {}, {}
  if o.namespace_style == "nested" then
    local name = table.concat(missing, "::")
    open[1] = "namespace " .. name .. " {"
    close[1] = "}" .. (o.namespace_close_comment and (" // namespace " .. name) or "")
  else
    for _, n in ipairs(missing) do
      open[#open + 1] = "namespace " .. n .. " {"
      table.insert(close, 1, "}" .. (o.namespace_close_comment and (" // namespace " .. n) or ""))
    end
  end
  local out = {}
  vim.list_extend(out, open)
  for _, item in ipairs(items) do
    out[#out + 1] = ""
    vim.list_extend(out, item)
  end
  out[#out + 1] = ""
  vim.list_extend(out, close)
  return out
end

function SourceInserter:finish()
  local sp, b, buf = self.sp, self.batch, self.buf
  local lines = sp.lines
  local is_new = #lines == 0 or (#lines == 1 and lines[1] == "")
  local sep = config.options.blank_lines_between or 1
  local function blanks(n)
    local t = {}
    for _ = 1, n do
      t[#t + 1] = ""
    end
    return t
  end
  -- Kopf neuer Dateien
  if is_new and self.opts.include then
    b:insert_lines(buf, 0, { '#include "' .. self.opts.include .. '"' })
  end
  -- using namespace
  local usings = vim.tbl_values(self.need_using)
  if #usings > 0 then
    local row = 0
    for _, inc in ipairs(sp.includes) do
      row = math.max(row, inc.line + 1)
    end
    local ul = { "" }
    for _, u in ipairs(usings) do
      ul[#ul + 1] = "using namespace " .. path_key(u) .. ";"
    end
    b:insert_lines(buf, row, ul)
  end
  local pts = vim.tbl_values(self.points)
  table.sort(pts, function(x, y)
    return x.seq < y.seq
  end)
  for _, pt in ipairs(pts) do
    local items = {}
    for _, it in ipairs(pt.items) do
      if it.missing then
        items[#items + 1] = namespace_block(it.missing, it.items)
      else
        items[#items + 1] = it
      end
    end
    local out = {}
    if pt.mode == "after" then
      for _, it in ipairs(items) do
        vim.list_extend(out, blanks(sep))
        vim.list_extend(out, it)
      end
    elseif pt.mode == "before" then
      for _, it in ipairs(items) do
        vim.list_extend(out, it)
        vim.list_extend(out, blanks(sep))
      end
    elseif pt.mode == "close" then
      local prev = lines[pt.row] -- Zeile vor der schließenden Klammer
      local open_line_before = false
      for _, ns in ipairs(sp.namespaces) do
        if ns.close_line == pt.row and ns.open_line == pt.row - 1 then
          open_line_before = true
        end
      end
      if not is_blank(prev) and not open_line_before then
        vim.list_extend(out, blanks(sep))
      elseif open_line_before then
        out[#out + 1] = ""
      end
      for i, it in ipairs(items) do
        vim.list_extend(out, it)
        out[#out + 1] = ""
        if i < #items and sep > 1 then
          vim.list_extend(out, blanks(sep - 1))
        end
      end
    else -- eof
      local last = lines[#lines]
      for i, it in ipairs(items) do
        if i > 1 or (not is_blank(last) and #lines > 0) or (is_new and self.opts.include) then
          vim.list_extend(out, blanks(sep))
        end
        vim.list_extend(out, it)
      end
    end
    b:insert_lines(buf, pt.row, out)
  end
end

return M
