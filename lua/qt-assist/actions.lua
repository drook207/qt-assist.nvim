-- Determine and run the available actions at the cursor position.
local config = require("qt-assist.config")
local parser = require("qt-assist.parser")
local lexer = require("qt-assist.lexer")
local codegen = require("qt-assist.codegen")
local edits = require("qt-assist.edits")
local naming = require("qt-assist.naming")
local source = require("qt-assist.source")

local M = {}

local uv = vim.uv or vim.loop

local function notify(msg, level)
  vim.notify("qt-assist: " .. msg, level or vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Parse cache
-- ---------------------------------------------------------------------------

local buf_cache = {} -- buf → { tick, parsed }
local file_cache = {} -- path → { mtime, size, parsed }

function M.parse_buf(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = buf_cache[buf]
  if c and c.tick == tick then
    return c.parsed
  end
  local p = parser.parse(edits.lines(buf))
  buf_cache[buf] = { tick = tick, parsed = p }
  return p
end

--- Parse a file (buffer preferred)
function M.parse_path(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return M.parse_buf(buf)
  end
  local st = uv.fs_stat(path)
  if not st then
    return parser.parse({ "" })
  end
  local c = file_cache[path]
  if c and c.mtime == st.mtime.sec and c.size == st.size then
    return c.parsed
  end
  local p = parser.parse(vim.fn.readfile(path))
  file_cache[path] = { mtime = st.mtime.sec, size = st.size, parsed = p }
  return p
end

local source_cache = {} -- header → { time, path }

local function cached_source(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local c = source_cache[name]
  local now = uv.now()
  if c and now - c.time < 5000 and (not c.path or uv.fs_stat(c.path)) then
    return c.path
  end
  local path = source.find_source(buf)
  source_cache[name] = { time = now, path = path }
  return path
end

function M.clear_cache()
  buf_cache, file_cache, source_cache = {}, {}, {}
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function class_function_names(cls)
  local names = {}
  for _, m in ipairs(cls.members) do
    if m.kind == "function" then
      names[m.name] = m
    end
  end
  return names
end

local function class_property_names(cls)
  local names = {}
  for _, pr in ipairs(cls.properties) do
    local info = parser.parse_property(pr.args)
    if info.name then
      names[info.name] = info
    end
  end
  return names
end

local function class_functions(cls)
  local res = {}
  for _, m in ipairs(cls.members) do
    if m.kind == "function" then
      res[#res + 1] = m
    end
  end
  return res
end

--- Declarations before/after d in the class (nearest first)
local function neighbours(cls, d)
  local fns = class_functions(cls)
  local idx
  for i, f in ipairs(fns) do
    if f == d then
      idx = i
    end
  end
  local prev, nxt = {}, {}
  if not idx then
    for i = #fns, 1, -1 do
      prev[#prev + 1] = fns[i]
    end
    return prev, nxt
  end
  for i = idx - 1, 1, -1 do
    prev[#prev + 1] = fns[i]
  end
  for i = idx + 1, #fns do
    nxt[#nxt + 1] = fns[i]
  end
  return prev, nxt
end

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

local function is_move_type(t)
  for _, m in ipairs(config.options.setter.move_types or {}) do
    if t:find(m, 1, true) then
      return true
    end
  end
  return false
end

local function short(path)
  return vim.fn.fnamemodify(path, ":t")
end

-- ---------------------------------------------------------------------------
-- Resolve target for definitions (asynchronous, possibly with a prompt)
-- ---------------------------------------------------------------------------

---@param ctx table
---@param cb fun(target: table) target = {kind="source", path=, new=} | {kind="header"}
local function resolve_target(ctx, cb)
  if ctx.is_source then
    cb({ kind = "same" })
    return
  end
  local path = cached_source(ctx.buf)
  if path then
    cb({ kind = "source", path = path })
    return
  end
  local mode = config.options.source.create_missing
  local proposal = source.default_source_path(ctx.path)
  if mode == true then
    cb({ kind = "source", path = proposal, new = true })
  elseif mode == "ask" then
    vim.ui.select({ "create", "header", "custom" }, {
      prompt = "No source file found for " .. short(ctx.path),
      format_item = function(item)
        if item == "create" then
          return "Create: " .. vim.fn.fnamemodify(proposal, ":~:.")
        elseif item == "header" then
          return "Define in the header (inline)"
        end
        return "Specify another path …"
      end,
    }, function(choice)
      if choice == "create" then
        cb({ kind = "source", path = proposal, new = true })
      elseif choice == "header" then
        cb({ kind = "header" })
      elseif choice == "custom" then
        vim.ui.input({ prompt = "Source file: ", default = proposal, completion = "file" }, function(input)
          if input and input ~= "" then
            local p = vim.fs.normalize(vim.fn.fnamemodify(input, ":p"))
            source_cache[ctx.path] = { time = uv.now(), path = p }
            cb({ kind = "source", path = p, new = uv.fs_stat(p) == nil })
          end
        end)
      end
    end)
  else
    cb({ kind = "header" })
  end
end

--- Prepare batch + inserter for a class
local function open_target(ctx, target, batch)
  if target.kind == "same" then
    return codegen.source_inserter(ctx.p, ctx.buf, batch), ctx.buf
  elseif target.kind == "source" then
    local sbuf = edits.load(target.path)
    local sp = parser.parse(edits.lines(sbuf))
    local inc = source.include_for(ctx.path, target.path)
    return codegen.source_inserter(sp, sbuf, batch, { include = inc }), sbuf
  end
end

local function finish(ctx, batch, action, sbuf)
  if batch:empty() then
    notify("nothing to do")
    return
  end
  local first = batch:apply()
  M.clear_cache()
  if config.options.jump_to_definition and sbuf and first[sbuf] then
    vim.cmd("drop " .. vim.fn.fnameescape(vim.api.nvim_buf_get_name(sbuf)))
    pcall(vim.api.nvim_win_set_cursor, 0, { first[sbuf] + 2, 0 })
  end
  if sbuf and sbuf ~= ctx.buf then
    notify(action .. " → " .. short(vim.api.nvim_buf_get_name(sbuf)) ..
      (config.options.auto_save and "" or " (not saved)"))
  end
  if type(config.options.on_generated) == "function" then
    pcall(config.options.on_generated, { header = ctx.buf, source = sbuf, action = action })
  end
end

-- ---------------------------------------------------------------------------
-- Getter / setter / signal / Q_PROPERTY
-- ---------------------------------------------------------------------------

--- Plan for a member variable or property
---@param ctx table
---@param spec table { member=, type=, base=, static=, want = {getter,setter,signal,reset,property,member_var}, names = {getter=,...} }
local function member_plan(ctx, spec)
  local cls = ctx.cls
  local n = naming.context(spec.member, spec.type, cls.name, spec.base)
  for k, v in pairs(spec.names or {}) do
    n[k] = v
  end
  local existing = class_function_names(cls)
  local props = class_property_names(cls)
  local w = spec.want
  local plan = { n = n, spec = spec }
  plan.getter = w.getter and not existing[n.getter]
  plan.setter = w.setter and not existing[n.setter] and not naming.is_const_object(spec.type)
  plan.signal = w.signal and not existing[n.signal] and not spec.static
  plan.reset = w.reset and not existing[n.reset] and not spec.static
  plan.property = w.property and not props[n.name] and not spec.static and w.property or nil
  plan.member_var = w.member_var
  -- Signal present (for emit in the setter)?
  plan.has_signal = not spec.static and (plan.signal or (existing[n.signal] ~= nil and (w.signal or w.property)))
  plan.any = plan.getter or plan.setter or plan.signal or plan.reset or plan.property or plan.member_var
  -- Constant member: do not offer variants that promise a setter
  if w.setter and naming.is_const_object(spec.type) then
    plan.any = false
  end
  return plan
end

--- Run all plans
local function run_member_plans(ctx, plans, action)
  local cls = ctx.cls
  local need_defs = false
  for _, pl in ipairs(plans) do
    if pl.getter or pl.setter or pl.reset then
      need_defs = true
    end
  end
  local mode = config.options.definitions
  if codegen.is_template_class(cls) and mode == "source" then
    mode = "header"
  end

  local function go(target)
    local batch = edits.batch()
    local ci = codegen.class_inserter(ctx.p, cls, ctx.buf, batch)
    local si, sbuf
    local where = mode
    if need_defs and mode == "source" then
      if target.kind == "header" then
        where = "header"
      else
        si, sbuf = open_target(ctx, target, batch)
      end
    end
    local unit = ci.unit
    local chain, tpls = codegen.class_qualifier(cls)
    local chain_str = table.concat(chain, "::") .. "::"
    -- New functions go at the end of the public section: the neighbours are
    -- the functions declared before them (nearest first)
    local prev = {}
    local pub_sec = ci:find_section({ access = "public", kind = "normal" })
    local bound = pub_sec and (pub_sec.last_line or pub_sec.line) or math.huge
    local fns = class_functions(cls)
    for i = #fns, 1, -1 do
      if fns[i].end_line <= bound then
        prev[#prev + 1] = fns[i]
      end
    end
    for i = #fns, 1, -1 do
      if fns[i].end_line > bound then
        prev[#prev + 1] = fns[i]
      end
    end

    --- Place a function: declaration in the class, body depending on the mode
    local function place(sec_spec, decl, sig_tail, ret, body, inline_getter)
      -- decl: complete declaration without ";"
      -- sig_tail: name + parameters + qualifiers, e.g. "foo() const"
      if where == "inline" or inline_getter then
        local lines = codegen.function_lines(decl, body, ci.member_indent, unit)
        ci:add(sec_spec, lines)
        return
      end
      ci:add_decl(sec_spec, decl .. ";")
      local function make(q)
        local r = ret
        -- qualify nested types
        r = r:gsub("()([%a_][%w_]*)", function(pos, word)
          if cls.nested_types[word] and not r:sub(1, pos - 1):match("::%s*$") then
            return q:gsub("::$", "") .. "::" .. word
          end
        end)
        return codegen.function_lines(join_ret(r, q .. sig_tail), body, "", unit, #tpls > 0 and tpls or nil)
      end
      if where == "header" then
        local lines = make(chain_str)
        if #tpls == 0 then
          lines[1] = "inline " .. lines[1]
        else
          -- Template: "inline" after the template lines
          lines[#tpls + 1] = "inline " .. lines[#tpls + 1]
        end
        ci:add_after_class(lines)
      else
        si:add(cls, make, prev, {})
      end
    end

    local o = config.options
    for _, pl in ipairs(plans) do
      local n, spec = pl.n, pl.spec
      local typ = spec.type
      local static = spec.static and "static " or ""
      local is_value = naming.is_value_type(typ, cls.nested_types)
      local pub = { access = "public", kind = "normal" }

      if pl.member_var then
        ci:add_decl({ access = "private", kind = "normal" }, naming.join_decl(typ, n.member) .. ";")
      end
      if pl.property then
        local tpl = o.property[pl.property] or o.property.full
        ci:add_property(naming.expand(tpl, n))
      end
      if pl.getter then
        local ret = typ
        if o.getter.return_by_const_ref and not is_value and not typ:match("&$") then
          ret = "const " .. typ .. " &"
        end
        local tail = n.getter .. "()" .. ((o.getter.const and not spec.static) and " const" or "")
        local decl = (o.getter.attributes or "") .. static .. join_ret(ret, tail)
        place(pub, decl, tail, ret, { "return " .. n.member .. ";" }, o.inline_getters)
      end
      local emit_line
      if pl.has_signal then
        local arg = o.signal.with_value and n.member or ""
        emit_line = o.signal.emit .. " " .. n.signal .. "(" .. arg .. ");"
      end
      if pl.setter then
        local ptype = naming.param_type(typ, cls.nested_types)
        local tail = n.setter .. "(" .. naming.join_decl(ptype, n.param) .. ")"
        local decl = static .. "void " .. tail
        local vars = vim.tbl_extend("force", n, {
          compare = naming.expand(naming.is_float(typ) and o.setter.fuzzy_compare or o.setter.compare, n),
          emit = o.signal.emit,
        })
        local body = {}
        if is_move_type(typ) then
          vars.param = "std::move(" .. n.param .. ")"
        end
        if emit_line then
          for _, l in ipairs(o.setter.body) do
            if l:match("^%s*{notify}%s*$") then
              body[#body + 1] = emit_line
            else
              body[#body + 1] = naming.expand(l, vars)
            end
          end
          -- Do not compare with std::move
          if is_move_type(typ) then
            body[1] = body[1]:gsub("std::move%((.-)%)", "%1")
          end
        else
          body[1] = n.member .. " = " .. vars.param .. ";"
        end
        local sec = o.setter.as_slot and cls.qobject and { access = "public", kind = "slots" } or pub
        place(sec, decl, tail, "void", body)
      end
      if pl.reset then
        local tail = n.reset .. "()"
        local body = {}
        for _, l in ipairs(o.reset_body) do
          body[#body + 1] = naming.expand(l, n)
        end
        place(pub, "void " .. tail, tail, "void", body)
      end
      if pl.signal then
        local params = ""
        if o.signal.with_value then
          params = naming.join_decl(naming.param_type(typ, cls.nested_types), n.name)
        end
        ci:add_decl({ kind = "signals", access = "public" }, "void " .. n.signal .. "(" .. params .. ");")
        ci:ensure_qobject("Q_OBJECT")
      end
      if pl.property and not cls.qobject then
        ci:ensure_qobject(pl.signal and "Q_OBJECT" or (pl.property == "constant" and "Q_GADGET" or "Q_OBJECT"))
      end
    end
    ci:finish()
    if si then
      si:finish()
    end
    finish(ctx, batch, action, sbuf)
  end

  if need_defs and mode == "source" then
    resolve_target(ctx, go)
  else
    go({ kind = "header" })
  end
end

local member_variants = {
  { id = "getset", title = "Getter and setter", want = { getter = true, setter = true } },
  { id = "getter", title = "Getter", want = { getter = true } },
  { id = "setter", title = "Setter", want = { setter = true } },
  { id = "getsetsig", title = "Getter, setter and changed signal", want = { getter = true, setter = true, signal = true } },
  { id = "property", title = "Q_PROPERTY and missing members", want = { getter = true, setter = true, signal = true, property = "full" } },
  { id = "property_reset", title = "Q_PROPERTY with reset and missing members", want = { getter = true, setter = true, signal = true, reset = true, property = "reset" } },
  { id = "property_const", title = "Constant Q_PROPERTY and getter", want = { getter = true, property = "constant" } },
}

-- ---------------------------------------------------------------------------
-- Definitions
-- ---------------------------------------------------------------------------

--- Generate definitions for declarations
---@param where string "source" | "inline" | "outside"
local function add_definitions(ctx, decls, where, action)
  local cls = ctx.cls
  if where == "source" and codegen.is_template_class(cls) then
    where = "outside"
  end
  local function go(target)
    local batch = edits.batch()
    local unit = edits.indent_unit(ctx.buf, ctx.p.lines)
    local chain, tpls = codegen.class_qualifier(cls)
    local chain_str = table.concat(chain, "::") .. "::"
    local si, sbuf
    local ci
    if where == "source" then
      if target.kind == "header" then
        where = "outside"
      else
        si, sbuf = open_target(ctx, target, batch)
      end
    end
    local function class_ins()
      ci = ci or codegen.class_inserter(ctx.p, cls, ctx.buf, batch)
      return ci
    end
    local body = config.options.empty_body or {}
    for _, d in ipairs(decls) do
      -- Member templates belong in the header
      local where = (where == "source" and d.template) and "outside" or where
      local prefix = vim.deepcopy(tpls)
      if d.template then
        prefix[#prefix + 1] = d.template:gsub("%s*=[^,>]*", "")
      end
      if where == "inline" then
        -- Replace ";" with a body
        local semi = ctx.p.toks[d.last_tok]
        local indent = ctx.p.lines[d.start_line + 1]:match("^(%s*)")
        local lines
        if config.options.brace_on_new_line then
          lines = { "", indent .. "{" }
          for _, l in ipairs(body) do
            lines[#lines + 1] = indent .. unit .. l
          end
          lines[#lines + 1] = indent .. "}"
        else
          lines = { " {" }
          for _, l in ipairs(body) do
            lines[#lines + 1] = indent .. unit .. l
          end
          lines[#lines + 1] = indent .. "}"
        end
        batch:replace(ctx.buf, semi.l, semi.c, semi.el, semi.ec, lines)
      else
        local function make(q)
          local sig = codegen.definition_signature(d, cls, q)
          return codegen.function_lines(sig, body, "", unit, #prefix > 0 and prefix or nil)
        end
        if where == "outside" then
          local lines = make(chain_str)
          if #prefix == 0 then
            lines[1] = "inline " .. lines[1]
          end
          class_ins():add_after_class(lines)
        else
          local prev, nxt = neighbours(cls, d)
          si:add(cls, make, prev, nxt)
        end
      end
    end
    if ci then
      ci:finish()
    end
    if si then
      si:finish()
    end
    finish(ctx, batch, action, sbuf)
  end
  if where == "source" then
    resolve_target(ctx, go)
  else
    go({ kind = "header" })
  end
end

--- Move an inline definition from the class into the source file
local function move_definition(ctx, d, action)
  local cls = ctx.cls
  resolve_target(ctx, function(target)
    if target.kind == "header" then
      notify("no source file – move cancelled", vim.log.levels.WARN)
      return
    end
    local p, toks = ctx.p, ctx.p.toks
    local batch = edits.batch()
    local si, sbuf = open_target(ctx, target, batch)
    local unit = edits.indent_unit(ctx.buf, p.lines)
    -- Initializer list?
    local init_tok
    for k = d.paren_close + 1, d.body_open - 1 do
      if toks[k].s == ":" then
        init_tok = k
        break
      end
    end
    local head_end = (init_tok or d.body_open) - 1
    local he, bc = toks[head_end], toks[d.body_close]
    -- Header: replace the body with ";" (including the ";" after the definition)
    local end_tok = bc
    if toks[d.body_close + 1] and toks[d.body_close + 1].s == ";" and toks[d.body_close + 1].l == bc.l then
      end_tok = toks[d.body_close + 1]
    end
    batch:replace(ctx.buf, he.l, he.ec, end_tok.el, end_tok.ec, { ";" })
    -- Remove "inline"
    for k = d.first_tok, d.name_tok do
      if toks[k].s == "inline" then
        local t = toks[k]
        local line = p.lines[t.l + 1]
        local ec = t.ec
        while line:sub(ec + 1, ec + 1) == " " do
          ec = ec + 1
        end
        batch:replace(ctx.buf, t.l, t.c, t.el, ec, { "" })
      end
    end
    -- Take over the body
    local bo = toks[d.body_open]
    local body = {}
    if bo.l == bc.l then
      local inner = vim.trim(p.lines[bo.l + 1]:sub(bo.ec + 1, bc.c))
      if inner ~= "" then
        body[1] = inner
      end
    else
      local first_inner = vim.trim(p.lines[bo.l + 1]:sub(bo.ec + 1))
      if first_inner ~= "" then
        body[#body + 1] = first_inner
      end
      local inner = {}
      for l = bo.l + 2, bc.l do
        inner[#inner + 1] = p.lines[l]
      end
      local last_inner = vim.trim(p.lines[bc.l + 1]:sub(1, bc.c))
      if last_inner ~= "" then
        inner[#inner + 1] = p.lines[bc.l + 1]:sub(1, bc.c)
      end
      -- remove the common indentation
      local min
      for _, l in ipairs(inner) do
        if l:match("%S") then
          local ws = #l:match("^(%s*)")
          min = (not min or ws < min) and ws or min
        end
      end
      for _, l in ipairs(inner) do
        body[#body + 1] = l:match("%S") and l:sub((min or 0) + 1) or ""
      end
    end
    local init_text = init_tok and lexer.text(p.lines, toks, init_tok, d.body_open - 1)
    local chain, tpls = codegen.class_qualifier(cls)
    _ = chain
    local function make(q)
      local sig = codegen.definition_signature(d, cls, q)
      local lines = codegen.function_lines(sig, body, "", unit, #tpls > 0 and tpls or nil)
      if init_text then
        local at = #tpls + 2
        table.insert(lines, at, unit .. init_text)
      end
      return lines
    end
    local prev, nxt = neighbours(cls, d)
    si:add(cls, make, prev, nxt)
    si:finish()
    finish(ctx, batch, action, sbuf)
  end)
end

--- Add a declaration for a definition from the .cpp to the header
local function add_declaration(ctx, f, hpath, hcls, spec, action)
  local batch = edits.batch()
  local hbuf = edits.load(hpath)
  local hp = parser.parse(edits.lines(hbuf))
  -- Find the class again in the freshly parsed header
  local target
  for _, c in ipairs(hp.classes) do
    if table.concat(codegen.class_path(c), "::") == table.concat(codegen.class_path(hcls), "::") then
      target = c
    end
  end
  if not target then
    return
  end
  local ci = codegen.class_inserter(hp, target, hbuf, batch)
  local ret = f.ret or ""
  for _, n in ipairs(target.chain) do
    ret = ret:gsub("[%w_:]*%f[%w_]" .. vim.pesc(n) .. "::", "")
  end
  local decl = join_ret(ret, f.name .. "(" .. codegen.params_without_defaults(f) .. ")")
  if #f.trailing > 0 then
    decl = decl .. " " .. table.concat(f.trailing, " ")
  end
  if f.trailing_ret then
    decl = decl .. " -> " .. f.trailing_ret
  end
  ci:add_decl(spec, decl .. ";")
  ci:finish()
  finish({ buf = hbuf, path = hpath }, batch, action, hbuf)
end

-- ---------------------------------------------------------------------------
-- Collect actions
-- ---------------------------------------------------------------------------

---@class QtAssistAction
---@field title string
---@field kind string
---@field run fun()

--- Context at the cursor/range
---@param buf integer
---@param l1 integer 0-based
---@param l2 integer 0-based
function M.context(buf, l1, l2)
  local path = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
  local p = M.parse_buf(buf)
  local ctx = {
    buf = buf, path = path, p = p, l1 = l1, l2 = l2,
    is_source = source.is_source(path),
  }
  ctx.cls = parser.class_at(p, l1)
  if ctx.cls and l1 <= ctx.cls.open_line and l1 < ctx.cls.start_line then
    ctx.cls = nil
  end
  return ctx
end

--- All actions for a buffer and line range
---@return QtAssistAction[]
function M.collect(buf, l1, l2)
  l2 = l2 or l1
  local ok, res = pcall(M._collect, buf, l1, l2)
  if not ok then
    if vim.g.qt_assist_debug then
      notify("Error: " .. tostring(res), vim.log.levels.ERROR)
    end
    return {}
  end
  return res
end

function M._collect(buf, l1, l2)
  local ctx = M.context(buf, l1, l2)
  local actions = {}
  local function add(title, run)
    actions[#actions + 1] = { title = title, kind = "refactor.rewrite", run = run }
  end
  local cls = ctx.cls

  if cls then
    local members = parser.members_in(cls, l1, l2)
    local vars, decls, inline_defs = {}, {}, {}
    for _, m in ipairs(members) do
      if m.kind == "variable" and not m.specs.constexpr and not m.array then
        vars[#vars + 1] = m
      elseif m.kind == "function" then
        if m.has_body then
          inline_defs[#inline_defs + 1] = m
        elseif codegen.needs_definition(m) then
          decls[#decls + 1] = m
        end
      end
    end

    -- Member variables
    if #vars > 0 then
      local label = #vars == 1 and vars[1].name or (#vars .. " members")
      for _, v in ipairs(member_variants) do
        local plans = {}
        for _, var in ipairs(vars) do
          local pl = member_plan(ctx, {
            member = var.name, type = var.type .. (var.array and "" or ""),
            static = var.specs.static, want = v.want,
          })
          if pl.any then
            plans[#plans + 1] = pl
          end
        end
        if #plans > 0 then
          local title = v.title .. " for " .. label
          add(title, function()
            run_member_plans(ctx, plans, title)
          end)
        end
      end
    end

    -- Q_PROPERTY → missing members
    local props = parser.properties_in(cls, l1, l2)
    if #props > 0 and #members == 0 then
      local plans = {}
      for _, pr in ipairs(props) do
        local info = parser.parse_property(pr.args)
        if info.name and info.type ~= "" then
          local existing_member = info.member
          local nctx = naming.context(nil, info.type, cls.name, info.name)
          local member = existing_member or nctx.member
          local has_var = false
          for _, f in ipairs(cls.fields) do
            if f.name == member then
              has_var = true
            end
          end
          local pl = member_plan(ctx, {
            member = member, type = info.type, base = info.name,
            names = {
              getter = info.read, setter = info.write, signal = info.notify, reset = info.reset,
              member = member,
            },
            want = {
              getter = info.read ~= nil, setter = info.write ~= nil, signal = info.notify ~= nil,
              reset = info.reset ~= nil, member_var = not has_var,
            },
          })
          if pl.any then
            plans[#plans + 1] = pl
          end
        end
      end
      if #plans > 0 then
        local title = "Generate missing members for Q_PROPERTY"
        add(title, function()
          run_member_plans(ctx, plans, title)
        end)
      end
    end

    -- Function declarations
    local sp_index, target_name
    local function source_index()
      if sp_index ~= nil then
        return sp_index
      end
      if ctx.is_source then
        sp_index = codegen.source_index(ctx.p)
        target_name = short(ctx.path)
      else
        local spath = cached_source(buf)
        if spath then
          sp_index = codegen.source_index(M.parse_path(spath))
          target_name = short(spath)
        else
          sp_index = false
          if config.options.source.create_missing ~= false then
            target_name = short(source.default_source_path(ctx.path)) .. " (new)"
          end
        end
      end
      return sp_index
    end
    local header_index = codegen.source_index(ctx.p)
    local undefined = {}
    for _, d in ipairs(decls) do
      if not codegen.is_defined(d, cls, header_index, source_index() or nil) then
        undefined[#undefined + 1] = d
      end
    end
    local tmpl = codegen.is_template_class(cls)
    if #undefined > 0 then
      local label = #undefined == 1 and (undefined[1].name .. "()") or (#undefined .. " functions")
      if not tmpl then
        local tname = target_name or (source.default_source_path(ctx.path) and "source file")
        add("Generate definition for " .. label .. " in " .. tname, function()
          add_definitions(ctx, undefined, "source", "Definition created")
        end)
      end
      add("Generate definition for " .. label .. " outside the class", function()
        add_definitions(ctx, undefined, "outside", "Definition created")
      end)
      if #undefined == 1 then
        add("Generate definition for " .. label .. " in the class", function()
          add_definitions(ctx, undefined, "inline", "Definition created")
        end)
      end
    end

    -- Move inline definitions
    if #inline_defs == 1 and not tmpl and not ctx.is_source then
      local d = inline_defs[1]
      source_index()
      local tname = target_name or "source file"
      add("Move definition of " .. d.name .. "() to " .. tname, function()
        move_definition(ctx, d, "Definition moved")
      end)
    end

    -- All missing definitions of the class
    local all = {}
    for _, m in ipairs(cls.members) do
      if m.kind == "function" and codegen.needs_definition(m)
          and not codegen.is_defined(m, cls, header_index, source_index() or nil) then
        all[#all + 1] = m
      end
    end
    if #all > 0 and (#all ~= #undefined or #undefined > 1) and not tmpl then
      add(("Generate all missing definitions of %s in %s (%d)"):format(cls.name, target_name or "source file", #all), function()
        add_definitions(ctx, all, "source", "Definitions created")
      end)
    end
  end

  -- Definition in the .cpp without declaration → declaration in the header
  if ctx.is_source then
    local f = parser.function_at(ctx.p, l1)
    if f and not f.class and f.has_body and #f.qualifier > 0 and l1 <= (f.body_open and ctx.p.toks[f.body_open].l or f.start_line) then
      local sp = ctx.p
      local hpath = source.find_header(buf, sp)
      local candidates = {}
      local paths = {}
      for _, path in ipairs(codegen.def_class_paths(sp, f)) do
        paths[table.concat(path, "::")] = true
      end
      -- Classes from the header and from the source file itself
      local function scan(parsed, file)
        for _, c in ipairs(parsed.classes) do
          if paths[table.concat(codegen.class_path(c), "::")] then
            candidates[#candidates + 1] = { cls = c, path = file, parsed = parsed }
          end
        end
      end
      if hpath then
        scan(M.parse_path(hpath), hpath)
      end
      scan(ctx.p, ctx.path)
      local c = candidates[1]
      if c then
        local declared = false
        local key = codegen.sig_key(f, c.cls.chain)
        for _, m in ipairs(c.cls.members) do
          if m.kind == "function" and codegen.sig_key(m, c.cls.chain) == key then
            declared = true
          end
        end
        if not declared then
          for _, variant in ipairs({
            { "public declaration", { access = "public", kind = "normal" } },
            { "protected declaration", { access = "protected", kind = "normal" } },
            { "private declaration", { access = "private", kind = "normal" } },
            { "declaration as public slot", { access = "public", kind = "slots" } },
          }) do
            local title = ("Generate %s for %s() in %s"):format(variant[1], f.name, short(c.path))
            add(title, function()
              add_declaration(ctx, f, c.path, c.cls, variant[2], "Declaration created")
            end)
          end
        end
      end
    end
  end

  return actions
end

return M
