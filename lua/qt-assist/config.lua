local M = {}

---@class QtAssistConfig
M.defaults = {
  -- Naming patterns. Placeholders:
  --   {name}  base name from the member variable (mIsValid → isValid)
  --   {Name}  base name with an uppercase first letter (IsValid)
  --   {NAME}  base name in uppercase (ISVALID)
  --   {snake} base name in snake_case (is_valid)
  --   {type}  type of the member variable
  --   {class} class name
  -- A function also works instead of a string: function(ctx) return "..." end
  -- (ctx contains name, Name, type, member, class).
  naming = {
    -- Prefixes/suffixes removed from the member to form the base name.
    -- Prefixes that end in a letter ("m") are only removed when an
    -- uppercase letter follows (mFoo → foo, mode stays mode).
    member_prefixes = { "m_", "m", "_" },
    member_suffixes = { "_" },
    member = "m{Name}", -- for "create member variable from Q_PROPERTY"
    getter = "{name}",
    bool_getter = nil, -- e.g. "is{Name}"; nil → same as getter
    setter = "set{Name}",
    setter_param = "{name}",
    signal = "{name}Changed",
    reset = "reset{Name}",
  },

  -- Q_PROPERTY templates (placeholders as above plus {getter} {setter} {signal}
  -- {reset} {member})
  property = {
    full = "Q_PROPERTY({type} {name} READ {getter} WRITE {setter} NOTIFY {signal} FINAL)",
    reset = "Q_PROPERTY({type} {name} READ {getter} WRITE {setter} RESET {reset} NOTIFY {signal} FINAL)",
    constant = "Q_PROPERTY({type} {name} READ {getter} CONSTANT FINAL)",
    -- Where the Q_PROPERTY goes: "after_qobject" (after Q_OBJECT or the
    -- last existing Q_PROPERTY) or "private" (private section, like Qt Creator)
    placement = "after_qobject",
  },

  getter = {
    const = true, -- bool foo() const
    attributes = "", -- e.g. "[[nodiscard]] " or "Q_REQUIRED_RESULT "
    return_by_const_ref = false, -- const QString &name() const
  },
  setter = {
    as_slot = false, -- setter in "public slots:" instead of "public:"
    -- Body of the setter (lines). Placeholders: {member} {param} {signal}
    -- {emit} {compare}. Lines that contain only {notify} are omitted without a signal.
    body = {
      "if ({compare})",
      "{indent}return;",
      "{member} = {param};",
      "{notify}",
    },
    -- Equality check; qFuzzyCompare for floating-point numbers
    compare = "{member} == {param}",
    fuzzy_compare = "qFuzzyCompare({member}, {param})",
    move_types = { "std::unique_ptr" }, -- assignment via std::move
  },
  signal = {
    with_value = false, -- void fooChanged(bool foo) instead of void fooChanged()
    keyword = "signals", -- "signals" or "Q_SIGNALS" (for new sections)
    emit = "emit", -- "emit" or "Q_EMIT"
  },
  -- Body of the reset function (placeholders as for the setter plus {setter} {type})
  reset_body = { "{setter}({type}{}); // TODO: default value" },

  -- Types passed by value (substring comparison after removing
  -- namespaces and template arguments, as in Qt Creator). Pointers and
  -- class enums are always passed by value.
  value_types = {
    "Pointer", "optional", "unique_ptr", "int", "long", "char", "real", "short",
    "unsigned", "size", "float", "double", "bool", "qint", "quint", "qreal", "qsizetype", "QPoint",
    "QSize", "QFlags", "QChar", "WId",
  },

  -- Where function bodies for generated getters/setters go:
  --   "source"  → in the .cpp (fallback "header" if none is found/created)
  --   "header"  → after the class in the header (inline)
  --   "inline"  → directly in the class
  definitions = "source",
  -- Small getters always directly in the class? (Qt Creator option "getterOutsideClassFrom")
  inline_getters = false,

  -- Missing namespaces in the .cpp:
  --   "create"   → create namespace a { namespace b { ... } }
  --   "qualify"  → fully qualify the name (a::b::Foo::bar)
  --   "using"    → insert using namespace a::b;
  missing_namespace = "create",
  -- "nested" → namespace a::b {   (C++17)    "separate" → namespace a { namespace b {
  namespace_style = "nested",
  namespace_close_comment = true, -- } // namespace a::b

  -- Layout of the function definitions
  brace_on_new_line = true,
  empty_body = {}, -- lines in the body of new (empty) definitions
  blank_lines_between = 1,

  -- Indentation: nil = detect automatically from the buffer/file
  indent = nil,

  -- Finding the source file
  source = {
    extensions = { "cpp", "cc", "cxx", "c++", "C" },
    header_extensions = { "h", "hpp", "hh", "hxx", "h++", "H" },
    -- Additional relative search paths (from the header's directory)
    search_dirs = { ".", "../src", "../source", "../Source", "src", "../../src" },
    use_clangd = true, -- textDocument/switchSourceHeader
    use_compile_commands = true,
    -- Fixed path to compile_commands.json or function(bufnr) → path
    compile_commands = nil,
    -- Create a missing .cpp? true | false | "ask"
    create_missing = "ask",
  },

  -- Save edited files? Otherwise they stay modified in the buffer.
  auto_save = false,
  -- Jump to the new definition after generating?
  jump_to_definition = false,

  -- Expose code actions through a small in-process language server
  -- (they appear in vim.lsp.buf.code_action() next to clangd)
  lsp = {
    enabled = true,
    filetypes = { "cpp", "c", "objcpp", "cuda" },
    name = "qt-assist",
  },

  -- Called after every generation: function(info) end
  -- info = { header = bufnr, source = bufnr|nil, action = "..." }
  on_generated = nil,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- Replace lists instead of merging them
  for _, key in ipairs({ "value_types" }) do
    if opts and opts[key] then
      M.options[key] = opts[key]
    end
  end
  if opts and opts.naming then
    for _, key in ipairs({ "member_prefixes", "member_suffixes" }) do
      if opts.naming[key] then
        M.options.naming[key] = opts.naming[key]
      end
    end
  end
  if opts and opts.source then
    for _, key in ipairs({ "extensions", "header_extensions", "search_dirs" }) do
      if opts.source[key] then
        M.options.source[key] = opts.source[key]
      end
    end
  end
  if opts and opts.setter and opts.setter.body then
    M.options.setter.body = opts.setter.body
  end
  if opts and opts.empty_body then
    M.options.empty_body = opts.empty_body
  end
  return M.options
end

return M
