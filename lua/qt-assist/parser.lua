-- Strukturparser für C++-Header und -Quellen auf Basis des Tokenizers.
-- Absichtlich fehlertolerant und Qt-bewusst (Q_OBJECT, signals:, public slots:,
-- Q_PROPERTY(...), Q_INVOKABLE, ...). Kein vollständiger C++-Parser – er erkennt
-- genau das, was für die Code-Generierung gebraucht wird:
--   * Namespaces (inkl. a::b, inline, anonym) mit Klammer-Positionen
--   * Klassen/Structs (verschachtelt) mit Abschnitten und Membern
--   * Funktionsdeklarationen und -definitionen (auch Out-of-Class: Foo::bar())
--   * Membervariablen, Q_PROPERTY-Makros, verschachtelte Typnamen
--   * using namespace / #include
local lexer = require("qt-assist.lexer")

local M = {}

local access_words = { public = true, protected = true, private = true }
local signal_words = { signals = true, Q_SIGNALS = true }
local slot_words = { slots = true, Q_SLOTS = true }

local decl_specifiers = {
  virtual = true, static = true, inline = true, explicit = true, friend = true,
  constexpr = true, consteval = true, extern = true, mutable = true,
  Q_INVOKABLE = true, Q_SLOT = true, Q_SIGNAL = true, Q_SCRIPTABLE = true,
  Q_DECL_EXPORT = true, Q_DECL_IMPORT = true,
}
M.decl_specifiers = decl_specifiers

local builtin_type_words = {
  int = true, char = true, bool = true, float = true, double = true, long = true,
  short = true, unsigned = true, signed = true, void = true, auto = true,
  const = true, volatile = true, wchar_t = true, char8_t = true, char16_t = true, char32_t = true,
}

local function is_macro_name(s)
  return s:match("^[A-Z][A-Z0-9_]*$") ~= nil and #s > 1
end

---@class QtAssistParsed
---@field lines string[]
---@field toks QtAssistToken[]
---@field root table   Datei-Scope
---@field classes table[] alle Klassen (flach)
---@field functions table[] alle Funktionen (flach, Deklarationen + Definitionen)
---@field namespaces table[] alle Namespace-Blöcke (flach)
---@field usings string[][] using-namespace-Direktiven (Dateiebene, als Pfad)
---@field includes table[] {path=, line=}

--- Index des passenden schließenden Tokens (für ( [ {)
local pairs_close = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local function match_close(toks, i)
  local open = toks[i].s
  local close = pairs_close[open]
  local depth = 0
  for k = i, #toks do
    local s = toks[k].s
    if toks[k].t == "punct" then
      if s == open then
        depth = depth + 1
      elseif s == close then
        depth = depth - 1
        if depth == 0 then
          return k
        end
      end
    end
  end
  return #toks
end
M.match_close = match_close

--- Zu "<" passendes ">" (Template-Argumente), nil falls keins gefunden
local function match_angle(toks, i, limit)
  local depth = 0
  local k = i
  while k <= limit do
    local s = toks[k].s
    if toks[k].t == "punct" then
      if s == "<" then
        depth = depth + 1
      elseif s == ">" then
        depth = depth - 1
        if depth == 0 then
          return k
        end
      elseif s == "(" or s == "[" or s == "{" then
        k = match_close(toks, k)
      elseif s == ";" or s == ")" or s == "}" then
        return nil
      end
    end
    k = k + 1
  end
end

local function text(p, i, j)
  return lexer.text(p.lines, p.toks, i, j)
end

-- ---------------------------------------------------------------------------
-- Analyse einer einzelnen Deklaration (Tokens a..b, ohne ; oder Rumpf)
-- ---------------------------------------------------------------------------

--- Parameterliste (Tokens zwischen den Klammern) zerlegen
local function parse_params(p, a, b)
  local toks = p.toks
  local params = {}
  if b < a then
    return params
  end
  local start = a
  local k = a
  local function finish(e)
    if e < start then
      return
    end
    -- Default-Wert abtrennen (erstes "=" auf oberster Ebene)
    local eq
    local m = start
    while m <= e do
      local s = toks[m].s
      if toks[m].t == "punct" then
        if s == "(" or s == "[" or s == "{" then
          m = match_close(toks, m)
        elseif s == "<" then
          m = match_angle(toks, m, e) or m
        elseif s == "=" then
          eq = m
          break
        end
      end
      m = m + 1
    end
    local decl_end = eq and eq - 1 or e
    local full = text(p, start, decl_end)
    if full == "void" and a == start and e == b then
      return
    end
    -- Parametername: letzter Bezeichner, wenn davor noch Typ-Tokens stehen
    local name, type_end = nil, decl_end
    local last = toks[decl_end]
    local arr_suffix = ""
    if last.s == "]" then
      -- int a[3]
      local k2 = decl_end
      while k2 > start and toks[k2].s ~= "[" do
        k2 = k2 - 1
      end
      arr_suffix = text(p, k2, decl_end)
      last = toks[k2 - 1]
      type_end = k2 - 1
    end
    if last and last.t == "id" and type_end > start and not builtin_type_words[last.s] then
      local prev = toks[type_end - 1]
      if prev.s ~= "::" and prev.s ~= "struct" and prev.s ~= "class" and prev.s ~= "enum" then
        name = last.s
        type_end = type_end - 1
      end
    end
    local typ = text(p, start, type_end) .. (name and "" or arr_suffix)
    if name and arr_suffix ~= "" then
      typ = typ .. arr_suffix -- nur für Vergleich
    end
    params[#params + 1] = {
      text = full, -- ohne Default
      type = typ,
      name = name,
      default = eq and text(p, eq + 1, e) or nil,
      variadic = full == "...",
    }
  end
  while k <= b do
    local s = toks[k].s
    if toks[k].t == "punct" then
      if s == "(" or s == "[" or s == "{" then
        k = match_close(toks, k)
      elseif s == "<" then
        k = match_angle(toks, k, b) or k
      elseif s == "," then
        finish(k - 1)
        start = k + 1
      end
    end
    k = k + 1
  end
  finish(b)
  return params
end

--- Normalisierter Typ für Signaturvergleiche
function M.normalize_type(s)
  s = s:gsub("%s*([%*&,<>%(%)%[%]])%s*", "%1")
  s = s:gsub("%s+", " ")
  -- "const T" == "T const" wird nicht normalisiert, aber Top-Level-const bei
  -- Wertparametern ist für die Signatur irrelevant
  s = s:gsub("^const ([%w_:<>, ]+)$", "%1")
  return vim.trim(s)
end

--- Erkennt Funktion oder Variable in den Tokens a..b
---@return table|nil
local function analyze_decl(p, a, b)
  local toks = p.toks
  if b < a then
    return nil
  end
  local first = toks[a].s
  if first == "using" or first == "typedef" or first == "friend" or first == "static_assert"
      or first == "namespace" then
    return nil
  end
  -- template<...> Präfix
  local template
  if first == "template" and toks[a + 1] and toks[a + 1].s == "<" then
    local close = match_angle(toks, a + 1, b)
    if not close then
      return nil
    end
    template = text(p, a, close)
    a = close + 1
    if a > b then
      return nil
    end
  end
  -- [[attribute]] überspringen
  local attrs = {}
  while toks[a] and toks[a].s == "[" and toks[a + 1] and toks[a + 1].s == "[" do
    local close = match_close(toks, a)
    attrs[#attrs + 1] = text(p, a, close)
    a = close + 1
  end

  -- Erste Klammer auf oberster Ebene (Templates und Initialisierer beachten)
  local k = a
  local paren
  local eq
  local brace_init
  while k <= b do
    local tk = toks[k]
    local s = tk.s
    if s == "operator" and tk.t == "id" and not eq and not paren then
      -- Operatorname bis zur Parameterliste überspringen: operator==, operator(), operator bool
      local m = k + 1
      if toks[m] and toks[m].s == "(" and toks[m + 1] and toks[m + 1].s == ")" then
        m = m + 2
      end
      while m <= b and toks[m].s ~= "(" do
        m = m + 1
      end
      if m <= b then
        paren = m
        k = match_close(toks, m)
      end
    elseif tk.t == "punct" then
      if s == "<" and not eq then
        local prev = toks[k - 1]
        if prev and prev.s == "operator" then
          -- operator<
        else
          k = match_angle(toks, k, b) or k
        end
      elseif s == "(" then
        local prev = toks[k - 1]
        if not eq and not paren and prev and (prev.t == "id" or prev.s == ">" or prev.s == "]" or prev.s == ")") then
          if prev.s == "operator" then
            -- operator()(...)
            k = match_close(toks, k)
          elseif toks[k + 1] and (toks[k + 1].s == "*" or toks[k + 1].s == "&") and prev.t ~= "id" then
            return nil -- Funktionszeiger, nicht unterstützt
          else
            paren = k
            k = match_close(toks, k)
          end
        else
          k = match_close(toks, k)
        end
      elseif s == "[" or s == "{" then
        if s == "{" and not paren and not eq then
          brace_init = brace_init or k
        end
        k = match_close(toks, k)
      elseif s == "=" then
        local prev = toks[k - 1]
        if not (prev and prev.s == "operator") then
          eq = eq or k
        end
      elseif s == ":" and not paren and not eq then
        -- Bitfeld: int x : 3
        eq = eq or k
      end
    end
    k = k + 1
  end

  local res = { template = template, attrs = attrs, first = a, last = b }

  if paren and (not eq or eq > paren) and (not brace_init or brace_init > paren) then
    -- Funktion
    local pclose = match_close(toks, paren)
    local name_end = paren - 1
    -- Name rückwärts einsammeln: id, ~id, operator xx, Qualifizierer a::b::
    local name_start = name_end
    local op_idx
    for m = name_end, a, -1 do
      if toks[m].s == "operator" then
        op_idx = m
        break
      end
      if toks[m].t ~= "punct" or toks[m].s == "(" or toks[m].s == ";" then
        -- weiter unten
      end
      if m < name_end - 4 then
        break
      end
    end
    if op_idx then
      name_start = op_idx
    else
      if toks[name_end].s == ">" then
        -- Spezialisierung foo<int>(): Templateargumente zurücklaufen
        local depth = 0
        for m = name_end, a, -1 do
          if toks[m].s == ">" then
            depth = depth + 1
          elseif toks[m].s == "<" then
            depth = depth - 1
            if depth == 0 then
              name_start = m - 1
              break
            end
          end
        end
      end
      if toks[name_start].t ~= "id" then
        return nil
      end
      if toks[name_start - 1] and toks[name_start - 1].s == "~" then
        name_start = name_start - 1
      end
    end
    -- Qualifizierer davor: X::  X<T>::
    local q_start = name_start
    while toks[q_start - 1] and toks[q_start - 1].s == "::" and q_start - 2 >= a do
      local m = q_start - 2
      if toks[m].s == ">" then
        local depth = 0
        while m >= a do
          if toks[m].s == ">" then
            depth = depth + 1
          elseif toks[m].s == "<" then
            depth = depth - 1
            if depth == 0 then
              m = m - 1
              break
            end
          end
          m = m - 1
        end
      end
      if not toks[m] or toks[m].t ~= "id" then
        break
      end
      q_start = m
    end
    if toks[q_start - 1] and toks[q_start - 1].s == "::" and q_start - 1 == a then
      q_start = a -- ::foo()
    end
    local name = text(p, name_start, name_end):gsub("%s+", function(sp)
      return sp
    end)
    local qualifier = {}
    if q_start < name_start then
      local qtext = text(p, q_start, name_start - 1) -- "A::B<T>::"
      for part in qtext:gmatch("([^:]+)::") do
        part = vim.trim(part)
        if part ~= "" then
          qualifier[#qualifier + 1] = part
        end
      end
    end
    -- Rückgabetyp und Spezifizierer
    local specs = {}
    local ret_start
    for m = a, q_start - 1 do
      local s = toks[m].s
      if decl_specifiers[s] and not ret_start then
        specs[s] = true
      elseif toks[m].t == "id" and is_macro_name(s) and not ret_start and m < q_start - 1
          and toks[m + 1].t == "id" and s:match("^Q_") then
        specs[s] = true -- Q_REQUIRED_RESULT, Q_DECL_... usw.
      else
        ret_start = ret_start or m
      end
    end
    local ret = ret_start and text(p, ret_start, q_start - 1) or ""
    -- Nach den Parametern
    local trailing = {}
    local m = pclose + 1
    local pure, defaulted, deleted, trailing_ret
    local post_specs = {}
    while m <= b do
      local s = toks[m].s
      if s == "const" or s == "volatile" or s == "&" or s == "&&" then
        trailing[#trailing + 1] = s
      elseif s == "noexcept" or s == "throw" then
        local e = m
        if toks[m + 1] and toks[m + 1].s == "(" then
          e = match_close(toks, m + 1)
        end
        trailing[#trailing + 1] = text(p, m, e)
        m = e
      elseif s == "override" or s == "final" or s == "Q_DECL_OVERRIDE" or s == "Q_DECL_FINAL" then
        post_specs[s] = true
      elseif s == "->" then
        local e = m + 1
        while e <= b and toks[e].s ~= "=" and toks[e].s ~= "override" and toks[e].s ~= "final" and toks[e].s ~= "{" do
          if toks[e].s == "<" then
            e = match_angle(toks, e, b) or e
          end
          e = e + 1
        end
        trailing_ret = text(p, m + 1, e - 1)
        m = e - 1
      elseif s == "=" then
        local v = toks[m + 1] and toks[m + 1].s
        if v == "0" then
          pure = true
        elseif v == "default" then
          defaulted = true
        elseif v == "delete" then
          deleted = true
        end
        m = m + 1
      elseif s == ":" then
        break -- Konstruktor-Initialisierungsliste (bei Definitionen)
      elseif s == "[" and toks[m + 1] and toks[m + 1].s == "[" then
        m = match_close(toks, m)
      end
      m = m + 1
    end
    res.kind = "function"
    res.name = name
    res.qualifier = qualifier
    res.ret = ret
    res.specs = specs
    res.post_specs = post_specs
    res.params = parse_params(p, paren + 1, pclose - 1)
    res.params_text = text(p, paren + 1, pclose - 1)
    res.trailing = trailing
    res.trailing_ret = trailing_ret
    res.is_const = vim.tbl_contains(trailing, "const")
    res.pure, res.defaulted, res.deleted = pure, defaulted, deleted
    res.is_ctor_like = ret == "" -- Konstruktor/Destruktor/Konvertierung
    res.name_tok = name_start
    res.paren_close = pclose
    return res
  end

  -- Variable
  local name_end = (eq or brace_init or (b + 1)) - 1
  -- Arrays: int a[3]
  local arr
  if toks[name_end] and toks[name_end].s == "]" then
    local m = name_end
    while m > a and toks[m].s ~= "[" do
      m = m - 1
    end
    -- mehrere Dimensionen
    while toks[m - 1] and toks[m - 1].s == "]" do
      m = m - 1
      while m > a and toks[m].s ~= "[" do
        m = m - 1
      end
    end
    arr = text(p, m, name_end)
    name_end = m - 1
  end
  local nt = toks[name_end]
  if not nt or nt.t ~= "id" or name_end <= a then
    return nil
  end
  if builtin_type_words[nt.s] then
    return nil
  end
  -- mehrere Deklaratoren (int a, b;) → nur einfache Fälle
  for m = a, name_end do
    if toks[m].s == "," then
      local depth_ok = true
      for n = a, m do
        if toks[n].s == "<" then
          depth_ok = false
        end
      end
      if depth_ok then
        return nil
      end
    end
  end
  local specs = {}
  local tstart = a
  while tstart < name_end and decl_specifiers[toks[tstart].s] do
    specs[toks[tstart].s] = true
    tstart = tstart + 1
  end
  res.kind = "variable"
  res.name = nt.s
  res.name_tok = name_end
  res.type = text(p, tstart, name_end - 1) .. (arr and "" or "")
  res.array = arr
  res.specs = specs
  res.init = eq and text(p, eq + 1, b) or (brace_init and text(p, brace_init, b)) or nil
  return res
end
M.analyze_decl = analyze_decl

-- ---------------------------------------------------------------------------
-- Scope-Parser
-- ---------------------------------------------------------------------------

---@param lines string[]
---@return QtAssistParsed
function M.parse(lines)
  local p = {
    lines = lines,
    toks = lexer.tokenize(lines),
    classes = {},
    functions = {},
    namespaces = {},
    usings = {},
    includes = {},
  }
  local toks = p.toks
  local n = #toks

  for _, t in ipairs(toks) do
    if t.t == "pp" then
      local inc = t.s:match('^#%s*include%s*["<]([^">]+)[">]')
      if inc then
        p.includes[#p.includes + 1] = { path = inc, line = t.l, quoted = t.s:match('^#%s*include%s*"') ~= nil }
      end
    end
  end

  local root = { kind = "file", ns = {}, classes = {}, functions = {}, namespaces = {}, usings = {} }
  p.root = root

  local parse_scope -- forward

  --- Klassenkopf erkennen: (template<..>)? class|struct|union [attr] [macro] Name [final] [: bases] {
  local function class_head(a, brace)
    local k = a
    local template
    if toks[k].s == "template" and toks[k + 1] and toks[k + 1].s == "<" then
      local close = match_angle(toks, k + 1, brace)
      if not close then
        return nil
      end
      template = text(p, k, close)
      k = close + 1
    end
    local key = toks[k] and toks[k].s
    if key ~= "class" and key ~= "struct" and key ~= "union" then
      return nil
    end
    -- Name: letzter Bezeichner vor ":" / "final" / "{" (Export-Makros überspringen)
    local name, name_tok
    local m = k + 1
    while m < brace do
      local s = toks[m].s
      if s == ":" then
        break
      end
      if toks[m].t == "punct" and s == "[" then
        m = match_close(toks, m)
      elseif toks[m].t == "id" and s ~= "final" and s ~= "alignas" then
        if toks[m + 1] and toks[m + 1].s == "(" then
          m = match_close(toks, m + 1) -- Makro mit Argumenten
        else
          name, name_tok = s, m
        end
      elseif s == "<" then
        m = match_angle(toks, m, brace) or m -- Spezialisierung
      end
      m = m + 1
    end
    return { key = key, name = name or "", name_tok = name_tok, template = template, head_start = a }
  end

  --- Qt-Abschnitte und Makros innerhalb einer Klasse am Statement-Anfang
  ---@return integer|nil next, table|nil section
  local function try_section(k)
    local s = toks[k].s
    local nxt = toks[k + 1]
    if access_words[s] then
      if nxt and nxt.s == ":" then
        return k + 2, { access = s, kind = "normal", tok = k }
      end
      if nxt and slot_words[nxt.s] and toks[k + 2] and toks[k + 2].s == ":" then
        return k + 3, { access = s, kind = "slots", tok = k }
      end
    elseif signal_words[s] and nxt and nxt.s == ":" then
      return k + 2, { access = "public", kind = "signals", tok = k, keyword = s }
    elseif slot_words[s] and nxt and nxt.s == ":" then
      return k + 2, { access = "private", kind = "slots", tok = k }
    end
  end

  --- Allein stehende Makros (Q_OBJECT, Q_PROPERTY(...), Q_DISABLE_COPY(X), ...)
  local function try_macro(k, limit)
    local tk = toks[k]
    if tk.t ~= "id" or not is_macro_name(tk.s) then
      return nil
    end
    local e = k
    if toks[k + 1] and toks[k + 1].s == "(" then
      e = match_close(toks, k + 1)
    end
    local nxt = toks[e + 1]
    if nxt and nxt.s == ";" then
      return e + 1, e
    end
    if e + 1 > limit or not nxt or nxt.l > toks[e].el or nxt.s == "}" then
      return e, e
    end
  end

  --- Funktionsrumpf-Ende ab Token k (nach den Parametern): überspringt
  --- Initialisierungsliste, liefert Index der öffnenden Rumpfklammer
  local function find_body_open(k, limit)
    local m = k
    while m <= limit do
      local s = toks[m].s
      if s == "{" then
        local prev = toks[m - 1]
        -- Initialisierer a{1} innerhalb einer Initialisierungsliste
        if prev and (prev.t == "id" or prev.s == ">") and prev.s ~= "const" and prev.s ~= "override"
            and prev.s ~= "final" and prev.s ~= "noexcept" and prev.s ~= "volatile" and prev.s ~= "mutable"
            and prev.s ~= "try" then
          -- nur wenn wir in einer Initialisierungsliste sind
          local in_init = false
          for q = k, m - 1 do
            if toks[q].s == ":" then
              in_init = true
              break
            end
          end
          if in_init then
            m = match_close(toks, m)
          else
            return m
          end
        else
          return m
        end
      elseif s == "(" or s == "[" then
        m = match_close(toks, m)
      elseif s == ";" then
        return nil
      end
      m = m + 1
    end
  end

  --- Parsen eines Bereichs [k, limit] im Kontext scope
  ---@param scope table
  local function record_last(cls, k)
    if k - 1 >= cls.open and toks[k - 1] then
      local ln = toks[k - 1].el
      local sec = cls.sections[#cls.sections]
      if sec then
        sec.last_line = ln
      else
        cls.implicit_last = ln
      end
    end
  end

  parse_scope = function(scope, k, limit)
    local cls = scope.kind == "class" and scope or nil
    local stmt_start = nil
    while k <= limit do
      local tk = toks[k]
      local s = tk.s
      -- letzte belegte Zeile des aktuellen Abschnitts (Einfügepunkt)
      if cls and not stmt_start then
        record_last(cls, k)
      end
      if tk.t == "pp" then
        k = k + 1
      elseif not stmt_start and s == ";" then
        k = k + 1
      elseif not stmt_start and cls and try_section(k) then
        local nk, sec = try_section(k)
        sec.line = tk.l
        cls.sections[#cls.sections + 1] = sec
        k = nk
      elseif not stmt_start and cls and try_macro(k, limit) then
        local nk, e = try_macro(k, limit)
        local macro = { name = s, first = k, last = e, line = tk.l, end_line = toks[nk].el, section = cls.sections[#cls.sections] }
        if s == "Q_PROPERTY" and toks[k + 1] and toks[k + 1].s == "(" then
          macro.args = text(p, k + 2, e - 1)
          cls.properties[#cls.properties + 1] = macro
        end
        if s == "Q_OBJECT" or s == "Q_GADGET" or s == "Q_GADGET_EXPORT" or s == "Q_NAMESPACE" then
          cls.qobject = cls.qobject or macro
        end
        cls.macros[#cls.macros + 1] = macro
        k = nk + 1
      elseif not stmt_start and not cls and s == "extern" and toks[k + 1] and toks[k + 1].t == "str"
          and toks[k + 2] and toks[k + 2].s == "{" then
        local close = match_close(toks, k + 2)
        parse_scope(scope, k + 3, close - 1)
        k = close + 1
      elseif not stmt_start and (s == "namespace" or (s == "inline" and toks[k + 1] and toks[k + 1].s == "namespace")) then
        local m = s == "inline" and k + 2 or k + 1
        local names = {}
        while toks[m] and (toks[m].t == "id" or toks[m].s == "::") do
          if toks[m].t == "id" and toks[m].s ~= "inline" then
            names[#names + 1] = toks[m].s
          end
          m = m + 1
        end
        -- Attribute / Makros
        while toks[m] and toks[m].s ~= "{" and toks[m].s ~= "=" and toks[m].s ~= ";" do
          m = m + 1
        end
        if toks[m] and toks[m].s == "{" then
          local close = match_close(toks, m)
          local path = vim.list_extend(vim.deepcopy(scope.ns), names)
          if #names == 0 then
            path[#path + 1] = "" -- anonym
          end
          local ns = {
            kind = "namespace", names = names, ns = path, open = m, close = close,
            open_line = toks[m].l, close_line = toks[close].l, start = k, start_line = tk.l,
            parent = scope, classes = {}, functions = {}, namespaces = {}, usings = {},
          }
          scope.namespaces[#scope.namespaces + 1] = ns
          p.namespaces[#p.namespaces + 1] = ns
          parse_scope(ns, m + 1, close - 1)
          k = close + 1
        else
          -- namespace Alias
          while k <= limit and toks[k].s ~= ";" do
            k = k + 1
          end
          k = k + 1
        end
      else
        stmt_start = stmt_start or k
        if s == ";" then
          -- Deklaration fertig
          local a, b = stmt_start, k - 1
          if toks[a].s == "using" and toks[a + 1] and toks[a + 1].s == "namespace" then
            local path = {}
            for m = a + 2, b do
              if toks[m].t == "id" then
                path[#path + 1] = toks[m].s
              end
            end
            -- relativ zum aktuellen Namespace? (vereinfachend: absolut)
            scope.usings[#scope.usings + 1] = path
            if scope.kind == "file" then
              p.usings[#p.usings + 1] = path
            end
          elseif cls and (toks[a].s == "using" or toks[a].s == "typedef") then
            -- Typalias in Klasse: Name merken
            local alias
            if toks[a].s == "using" and toks[a + 2] and toks[a + 2].s == "=" then
              alias = toks[a + 1].s
            elseif toks[a].s == "typedef" and toks[b].t == "id" then
              alias = toks[b].s
            end
            if alias then
              cls.nested_types[alias] = true
            end
          elseif (toks[a].s == "class" or toks[a].s == "struct" or toks[a].s == "enum") and b - a <= 2 and cls then
            -- Vorwärtsdeklaration
            if toks[b].t == "id" then
              cls.nested_types[toks[b].s] = true
            end
          else
            local d = analyze_decl(p, a, b)
            if d then
              d.scope = scope
              d.class = cls
              d.ns = scope.ns
              d.start_line = toks[a].l
              d.end_line = toks[k].el
              d.first_tok, d.last_tok = a, k
              d.section = cls and cls.sections[#cls.sections] or nil
              d.has_body = false
              if d.kind == "function" then
                scope.functions[#scope.functions + 1] = d
                p.functions[#p.functions + 1] = d
              elseif cls then
                cls.fields[#cls.fields + 1] = d
              end
              if cls then
                cls.members[#cls.members + 1] = d
              end
            end
          end
          stmt_start = nil
          k = k + 1
        elseif s == "{" then
          local a = stmt_start
          local head = class_head(a, k)
          local first = toks[a].s
          if head then
            local close = match_close(toks, k)
            local cscope = {
              kind = "class", key = head.key, name = head.name, template = head.template,
              ns = scope.ns, parent = scope, outer = cls,
              open = k, close = close, open_line = toks[k].l, close_line = toks[close].l,
              start_line = toks[a].l, head_start = a,
              sections = {}, members = {}, fields = {}, functions = {}, properties = {}, macros = {},
              classes = {}, namespaces = {}, usings = {}, nested_types = {},
            }
            -- Default-Zugriff
            cscope.default_access = head.key == "class" and "private" or "public"
            cscope.chain = {}
            if cls then
              vim.list_extend(cscope.chain, cls.chain)
              cls.nested_types[head.name] = true
            end
            cscope.chain[#cscope.chain + 1] = head.name
            cscope.section = cls and cls.sections[#cls.sections] or nil
            scope.classes[#scope.classes + 1] = cscope
            p.classes[#p.classes + 1] = cscope
            parse_scope(cscope, k + 1, close - 1)
            -- bis zum ; nach der Klasse
            local m = close + 1
            while m <= limit and toks[m].s ~= ";" do
              m = m + 1
            end
            cscope.end_tok = math.min(m, n)
            cscope.end_line = toks[cscope.end_tok].el
            stmt_start = nil
            k = m + 1
          elseif first == "enum" or (first == "typedef" and toks[a + 1] and (toks[a + 1].s == "enum" or toks[a + 1].s == "struct")) then
            local close = match_close(toks, k)
            if cls then
              for m = a + 1, k - 1 do
                if toks[m].t == "id" and toks[m].s ~= "class" and toks[m].s ~= "struct" and toks[m].s ~= "enum" then
                  cls.nested_types[toks[m].s] = true
                  break
                end
              end
              -- typedef enum {..} Name;
              local m = close + 1
              if toks[m] and toks[m].t == "id" then
                cls.nested_types[toks[m].s] = true
              end
            end
            k = close + 1
            while k <= limit and toks[k].s ~= ";" do
              k = k + 1
            end
            stmt_start = nil
            k = k + 1
          else
            -- Funktion mit Rumpf oder Initialisierer
            local d = analyze_decl(p, a, k - 1)
            local body_open = k
            if d and d.kind == "function" then
              -- Initialisierungsliste: Rumpf weiter hinten
              local bo = find_body_open(d.paren_close + 1, limit)
              body_open = bo or k
              if bo and bo ~= k then
                d = analyze_decl(p, a, d.paren_close) or d
                -- trailing Qualifizierer vor ":" neu einlesen
                local d2 = analyze_decl(p, a, bo - 1)
                if d2 and d2.kind == "function" then
                  d = d2
                end
              end
            end
            if d and d.kind == "function" then
              local close = match_close(toks, body_open)
              d.scope = scope
              d.class = cls
              d.ns = scope.ns
              d.has_body = true
              d.body_open, d.body_close = body_open, close
              d.start_line = toks[a].l
              d.end_line = toks[close].el
              d.first_tok, d.last_tok = a, close
              d.section = cls and cls.sections[#cls.sections] or nil
              scope.functions[#scope.functions + 1] = d
              p.functions[#p.functions + 1] = d
              if cls then
                cls.members[#cls.members + 1] = d
              end
              stmt_start = nil
              k = close + 1
              -- optionales ; nach Inline-Definition
              if toks[k] and toks[k].s == ";" and k <= limit then
                k = k + 1
              end
            else
              -- Klammer-Initialisierer: überspringen, Statement läuft weiter
              k = match_close(toks, k) + 1
            end
          end
        elseif s == "(" or s == "[" then
          k = match_close(toks, k) + 1
        elseif s == "}" then
          -- unbalanciert – ignorieren
          stmt_start = nil
          k = k + 1
        else
          k = k + 1
        end
      end
    end
    if cls and not stmt_start then
      record_last(cls, math.min(k, limit + 1))
    end
  end

  parse_scope(root, 1, n)
  return p
end

-- ---------------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------------

--- Innerste Klasse, deren Rumpf die Zeile enthält
function M.class_at(p, line)
  local best
  for _, c in ipairs(p.classes) do
    if line >= c.start_line and line <= c.close_line then
      if not best or c.start_line >= best.start_line then
        best = c
      end
    end
  end
  return best
end

--- Member (Funktion/Variable/Property-Makro) an einer Zeile bzw. in einem Bereich
function M.members_in(cls, l1, l2)
  local res = {}
  for _, m in ipairs(cls.members) do
    if m.end_line >= l1 and m.start_line <= l2 then
      res[#res + 1] = m
    end
  end
  return res
end

function M.properties_in(cls, l1, l2)
  local res = {}
  for _, m in ipairs(cls.properties) do
    if m.end_line >= l1 and m.line <= l2 then
      res[#res + 1] = m
    end
  end
  return res
end

--- Funktion außerhalb von Klassen (z. B. Foo::bar() { } in der .cpp) an Zeile
function M.function_at(p, line)
  local best
  for _, f in ipairs(p.functions) do
    if line >= f.start_line and line <= f.end_line then
      if not best or f.start_line >= best.start_line then
        best = f
      end
    end
  end
  return best
end

--- Q_PROPERTY-Argumente zerlegen
function M.parse_property(args)
  local words = {}
  -- Typ kann Templates enthalten: alles bis zum Namen vor dem ersten Schlüsselwort
  local keywords = {
    READ = true, WRITE = true, NOTIFY = true, RESET = true, MEMBER = true, CONSTANT = true,
    FINAL = true, DESIGNABLE = true, SCRIPTABLE = true, STORED = true, USER = true,
    REVISION = true, BINDABLE = true, REQUIRED = true,
  }
  for w in args:gmatch("%S+") do
    words[#words + 1] = w
  end
  local kw_start = #words + 1
  for i, w in ipairs(words) do
    if keywords[w] then
      kw_start = i
      break
    end
  end
  local name = words[kw_start - 1]
  local typ = table.concat(vim.list_slice(words, 1, kw_start - 2), " ")
  -- "QString*name" / "const T &name" Sonderfälle
  if name and name:match("^[%*&]") then
    typ = typ .. " " .. name:match("^[%*&]+")
    name = name:gsub("^[%*&]+", "")
  end
  local res = { type = typ, name = name, flags = {} }
  local i = kw_start
  while i <= #words do
    local w = words[i]
    if w == "READ" or w == "WRITE" or w == "NOTIFY" or w == "RESET" or w == "MEMBER" or w == "BINDABLE" then
      res[w:lower()] = words[i + 1]
      i = i + 2
    elseif w == "REVISION" or w == "DESIGNABLE" or w == "SCRIPTABLE" or w == "STORED" or w == "USER" then
      res.flags[w] = words[i + 1] or true
      i = i + ((words[i + 1] and not keywords[words[i + 1]]) and 2 or 1)
    else
      res.flags[w] = true
      i = i + 1
    end
  end
  return res
end

--- Signatur-Schlüssel für Vergleiche Deklaration ↔ Definition
function M.signature_key(f)
  local types = {}
  for _, prm in ipairs(f.params) do
    types[#types + 1] = M.normalize_type(prm.type)
  end
  return f.name .. "(" .. table.concat(types, ",") .. ")" .. (f.is_const and "const" or "")
end

return M
