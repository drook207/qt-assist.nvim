-- Namensbildung nach konfigurierbaren Mustern
local config = require("qt-assist.config")

local M = {}

local function upper_first(s)
  return (s:gsub("^%l", string.upper))
end
local function lower_first(s)
  return (s:gsub("^%u", string.lower))
end
M.upper_first = upper_first
M.lower_first = lower_first

local function snake(s)
  return (s:gsub("(%l)(%u)", "%1_%2"):lower())
end

--- Basisname aus einem Membernamen (mIsValid → isValid, m_ratio → ratio, count_ → count)
function M.base_name(member)
  local o = config.options.naming
  local name = member
  for _, pre in ipairs(o.member_prefixes or {}) do
    if pre ~= "" and name:sub(1, #pre) == pre and #name > #pre then
      local rest = name:sub(#pre + 1)
      if pre:match("[%a%d]$") then
        -- Buchstaben-Präfix nur vor Großbuchstaben (mFoo, nicht mode)
        if rest:match("^%u") then
          name = lower_first(rest)
          break
        end
      else
        name = rest
        break
      end
    end
  end
  for _, suf in ipairs(o.member_suffixes or {}) do
    if suf ~= "" and #name > #suf and name:sub(-#suf) == suf then
      name = name:sub(1, -#suf - 1)
      break
    end
  end
  return name
end

--- Platzhalter in einer Vorlage ersetzen; unbekannte {..} bleiben stehen
function M.expand(tpl, ctx)
  if type(tpl) == "function" then
    return tpl(ctx)
  end
  return (tpl:gsub("{(%w+)}", function(k)
    local v = ctx[k]
    if v == nil then
      return nil
    end
    return tostring(v)
  end))
end

--- Kontext mit allen Namen für eine Membervariable
---@param member string Name der Membervariable
---@param typ string Typ
---@param class_name string|nil
---@param base string|nil Basisname vorgeben (z. B. aus Q_PROPERTY)
function M.context(member, typ, class_name, base)
  local o = config.options.naming
  local name = base or M.base_name(member)
  local ctx = {
    name = name,
    Name = upper_first(name),
    NAME = name:upper(),
    snake = snake(name),
    type = typ,
    member = member,
    class = class_name or "",
  }
  local is_bool = typ == "bool"
  local getter_tpl = (is_bool and o.bool_getter) or o.getter
  ctx.getter = M.expand(getter_tpl, ctx)
  if ctx.getter == member then
    -- Member ohne Präfix: Getter darf nicht wie die Variable heißen
    ctx.getter = "get" .. ctx.Name
  end
  ctx.setter = M.expand(o.setter, ctx)
  ctx.signal = M.expand(o.signal, ctx)
  ctx.reset = M.expand(o.reset, ctx)
  ctx.param = M.expand(o.setter_param, ctx)
  if ctx.param == member then
    ctx.param = "new" .. ctx.Name
  end
  if not member or member == "" then
    ctx.member = M.expand(o.member, ctx)
    if ctx.param == ctx.member then
      ctx.param = "new" .. ctx.Name
    end
  end
  return ctx
end

--- Typ ohne Namespaces/Template-Argumente/const/&/*
local function core_type(t)
  t = t:gsub("<.*>", "")
  t = t:gsub("%f[%w_]const%f[^%w_]", ""):gsub("%f[%w_]volatile%f[^%w_]", "")
  t = t:gsub("[%w_]+::", "")
  return vim.trim(t:gsub("[%*&]", ""))
end

--- Soll der Typ als Wert (statt const-Referenz) übergeben werden?
---@param nested table<string, boolean>|nil Enums/Typen der Klasse
function M.is_value_type(t, nested)
  if t:match("[%*&]%s*$") or t:match("%*") then
    return true
  end
  local core = core_type(t)
  if nested and nested[core] then
    return true -- (Enum der Klasse – verschachtelte Klassen sind seltener)
  end
  if core:match("^Q?[%w_]*Enum") or core:match("Flags?$") then
    return true
  end
  for w in core:gmatch("[%w_]+") do
    for _, v in ipairs(config.options.value_types) do
      if w == v or w == v .. "F" or w:match("^u?" .. vim.pesc(v) .. "%d*_?t?$")
          or (v:match("^%u") and w:sub(-#v) == v) then
        return true
      end
    end
  end
  return false
end

function M.is_float(t)
  local core = core_type(t)
  return core == "float" or core == "double" or core == "qreal" or core == "long double"
end

--- Parametertyp für den Setter
function M.param_type(t, nested)
  if t:match("&%s*$") or M.is_value_type(t, nested) then
    return t
  end
  return "const " .. t .. " &"
end

--- "const QString &" + "name" → "const QString &name"; "int" + "x" → "int x"
--- "QWidget*" → "QWidget *" (Qt-Stil, Zeiger/Referenz am Namen)
function M.spaced(t)
  return (t:gsub("([^%s%*&])([%*&]+)$", "%1 %2"))
end

--- Ist die Membervariable selbst konstant (kein Setter möglich)?
function M.is_const_object(t)
  t = vim.trim(t)
  if t:match("%f[%w_]const$") then
    return true -- int const, T *const
  end
  return t:match("^const%s") ~= nil and not t:find("*", 1, true)
end

function M.join_decl(typ, name)
  typ = M.spaced(typ)
  if typ:match("[%*&]$") then
    return typ .. name
  end
  return typ .. " " .. name
end

return M
