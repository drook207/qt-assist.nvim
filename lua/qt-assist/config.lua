local M = {}

---@class QtAssistConfig
M.defaults = {
  -- Namensmuster. Platzhalter:
  --   {name}  Basisname aus der Membervariable (mIsValid → isValid)
  --   {Name}  Basisname mit großem Anfangsbuchstaben (IsValid)
  --   {NAME}  Basisname in Großbuchstaben (ISVALID)
  --   {snake} Basisname in snake_case (is_valid)
  --   {type}  Typ der Membervariable
  --   {class} Klassenname
  -- Statt eines Strings geht auch eine Funktion: function(ctx) return "..." end
  -- (ctx enthält name, Name, type, member, class).
  naming = {
    -- Präfixe/Suffixe, die vom Member entfernt werden, um den Basisnamen zu
    -- bilden. Präfixe, die auf einen Buchstaben enden ("m"), werden nur
    -- entfernt, wenn danach ein Großbuchstabe folgt (mFoo → foo, mode bleibt mode).
    member_prefixes = { "m_", "m", "_" },
    member_suffixes = { "_" },
    member = "m{Name}", -- für "Membervariable aus Q_PROPERTY erzeugen"
    getter = "{name}",
    bool_getter = nil, -- z. B. "is{Name}"; nil → wie getter
    setter = "set{Name}",
    setter_param = "{name}",
    signal = "{name}Changed",
    reset = "reset{Name}",
  },

  -- Q_PROPERTY-Vorlagen (Platzhalter wie oben plus {getter} {setter} {signal}
  -- {reset} {member})
  property = {
    full = "Q_PROPERTY({type} {name} READ {getter} WRITE {setter} NOTIFY {signal} FINAL)",
    reset = "Q_PROPERTY({type} {name} READ {getter} WRITE {setter} RESET {reset} NOTIFY {signal} FINAL)",
    constant = "Q_PROPERTY({type} {name} READ {getter} CONSTANT FINAL)",
    -- Wohin die Q_PROPERTY kommt: "after_qobject" (hinter Q_OBJECT bzw. die
    -- letzte vorhandene Q_PROPERTY) oder "private" (privater Abschnitt, wie Qt Creator)
    placement = "after_qobject",
  },

  getter = {
    const = true, -- bool foo() const
    attributes = "", -- z. B. "[[nodiscard]] " oder "Q_REQUIRED_RESULT "
    return_by_const_ref = false, -- const QString &name() const
  },
  setter = {
    as_slot = false, -- Setter in "public slots:" statt "public:"
    -- Rumpf des Setters (Zeilen). Platzhalter: {member} {param} {signal}
    -- {emit} {compare}. Zeilen, die nur {notify} enthalten, entfallen ohne Signal.
    body = {
      "if ({compare})",
      "{indent}return;",
      "{member} = {param};",
      "{notify}",
    },
    -- Gleichheitsprüfung; für Fließkommazahlen qFuzzyCompare
    compare = "{member} == {param}",
    fuzzy_compare = "qFuzzyCompare({member}, {param})",
    move_types = { "std::unique_ptr" }, -- Zuweisung per std::move
  },
  signal = {
    with_value = false, -- void fooChanged(bool foo) statt void fooChanged()
    keyword = "signals", -- "signals" oder "Q_SIGNALS" (für neue Abschnitte)
    emit = "emit", -- "emit" oder "Q_EMIT"
  },
  -- Rumpf der Reset-Funktion (Platzhalter wie beim Setter plus {setter} {type})
  reset_body = { "{setter}({type}{}); // TODO: Standardwert" },

  -- Typen, die als Wert übergeben werden (Teilstring-Vergleich nach Entfernen
  -- von Namespaces und Template-Argumenten, wie in Qt Creator). Zeiger und
  -- Enums der Klasse werden immer als Wert übergeben.
  value_types = {
    "Pointer", "optional", "unique_ptr", "int", "long", "char", "real", "short",
    "unsigned", "size", "float", "double", "bool", "qint", "quint", "qreal", "qsizetype", "QPoint",
    "QSize", "QFlags", "QChar", "WId",
  },

  -- Wo Funktionsrümpfe für generierte Getter/Setter landen:
  --   "source"  → in der .cpp (Fallback "header", falls keine gefunden/angelegt)
  --   "header"  → hinter der Klasse im Header (inline)
  --   "inline"  → direkt in der Klasse
  definitions = "source",
  -- Kleine Getter immer direkt in der Klasse? (Qt-Creator-Option "getterOutsideClassFrom")
  inline_getters = false,

  -- Fehlende Namespaces in der .cpp:
  --   "create"   → namespace a { namespace b { ... } } anlegen
  --   "qualify"  → Name voll qualifizieren (a::b::Foo::bar)
  --   "using"    → using namespace a::b; einfügen
  missing_namespace = "create",
  -- "nested" → namespace a::b {   (C++17)    "separate" → namespace a { namespace b {
  namespace_style = "nested",
  namespace_close_comment = true, -- } // namespace a::b

  -- Aufbau der Funktionsdefinitionen
  brace_on_new_line = true,
  empty_body = {}, -- Zeilen im Rumpf neuer (leerer) Definitionen
  blank_lines_between = 1,

  -- Einrückung: nil = automatisch aus Buffer/Datei erkennen
  indent = nil,

  -- Quelldatei suchen
  source = {
    extensions = { "cpp", "cc", "cxx", "c++", "C" },
    header_extensions = { "h", "hpp", "hh", "hxx", "h++", "H" },
    -- Zusätzliche relative Suchpfade (vom Verzeichnis des Headers aus)
    search_dirs = { ".", "../src", "../source", "../Source", "src", "../../src" },
    use_clangd = true, -- textDocument/switchSourceHeader
    use_compile_commands = true,
    -- Fester Pfad zur compile_commands.json oder Funktion(bufnr) → Pfad
    compile_commands = nil,
    -- Fehlende .cpp anlegen? true | false | "ask"
    create_missing = "ask",
  },

  -- Bearbeitete Dateien speichern? Sonst bleiben sie geändert im Buffer.
  auto_save = false,
  -- Nach dem Erzeugen zur neuen Definition springen?
  jump_to_definition = false,

  -- Code-Actions über einen kleinen In-Process-Language-Server bereitstellen
  -- (erscheinen in vim.lsp.buf.code_action() neben clangd)
  lsp = {
    enabled = true,
    filetypes = { "cpp", "c", "objcpp", "cuda" },
    name = "qt-assist",
  },

  -- Wird nach jeder Generierung aufgerufen: function(info) end
  -- info = { header = bufnr, source = bufnr|nil, action = "..." }
  on_generated = nil,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- Listen ersetzen statt mischen
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
