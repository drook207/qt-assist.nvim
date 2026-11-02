# qt-assist.nvim

Qt Creator refactorings for Neovim: generate getters, setters, changed signals and
`Q_PROPERTY` from a member variable, write function definitions from the
header into the matching `.cpp` (including missing namespaces) – as plain
**code actions** (`vim.lsp.buf.code_action()`), right next to clangd's.

```cpp
// Header – cursor on mIsValid, code action
// "Q_PROPERTY and missing members for mIsValid"
class Person : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool isValid READ isValid WRITE setIsValid NOTIFY isValidChanged FINAL)  // new
public:
    bool isValid() const;                // new
    void setIsValid(bool isValid);       // new
signals:
    void isValidChanged();               // new
private:
    bool mIsValid = false;
};
```

```cpp
// person.cpp – automatic, in the correct namespace
bool Person::isValid() const
{
    return mIsValid;
}

void Person::setIsValid(bool isValid)
{
    if (mIsValid == isValid)
        return;
    mIsValid = isValid;
    emit isValidChanged();
}
```

## Features

| Cursor on | Code actions |
|---|---|
| Member variable (or visual selection over several) | Getter and setter · Getter · Setter · Getter, setter and changed signal · **Q_PROPERTY and missing members** · Q_PROPERTY with reset · constant Q_PROPERTY |
| `Q_PROPERTY(...)` line | Generate missing members (member variable, READ, WRITE, NOTIFY, RESET) |
| Function declaration in the header | Definition in `foo.cpp` · outside the class (inline in the header) · in the class |
| Inline definition in the class | Move definition to `foo.cpp` (including initializer list) |
| anywhere in the class | Generate all missing definitions in `foo.cpp` |
| Definition in the `.cpp` without declaration | Generate public/protected/private declaration or public slot in the header |

The following is taken into account:

- **Existing items** are not generated twice (getters, setters, signals, properties, definitions –
  even if they are fully qualified in the `.cpp` or written via `using namespace`).
- **Sections**: getters/setters in `public:`, signals in `signals:`/`Q_SIGNALS:`; missing sections
  are created at the end of the class, `Q_OBJECT` is added if needed.
- **Parameters**: classes by `const T &`, built-in types, pointers, class enums by value
  (list as in Qt Creator, configurable). Floating-point numbers are compared with `qFuzzyCompare`,
  `std::unique_ptr` is assigned via `std::move`.
- **Definitions**: default arguments, `virtual`, `static`, `override`, `Q_INVOKABLE` etc. are dropped;
  nested types in the return type are qualified (`Person::State Person::state() const`);
  pure virtual, `= default`/`= delete` and signals get no definition.
- **Order**: new definitions are placed after the definition of the previously declared function
  (as in Qt Creator) and adopt its spelling (`Person::` vs. `app::model::Person::`).
- **Namespaces**: missing namespace blocks are created in the `.cpp` (`namespace a::b {` or
  nested), alternatively fully qualified or via `using namespace` – see `missing_namespace`.
- **Templates**: class and member templates are defined in the header (with `template <…>`).
- Indentation (spaces/tabs, width) is taken from the file.

## How the `.cpp` is found

1. same directory, same name (`foo.h` → `foo.cpp`, `.cc`, `.cxx`, …)
2. clangd: `textDocument/switchSourceHeader`
3. **`compile_commands.json`** – source file with the same name that is closest to the header.
   The file is searched via:
   - [cmake-tools.nvim](https://github.com/Civitasv/cmake-tools.nvim) (`get_build_directory()`)
   - qmake-tools.nvim (build directory of the active configuration)
   - `--compile-commands-dir` or the root directory of the running clangd
   - upward search (also in `build*/`)
4. search paths (`../src`, `src`, …) and `include/x/y.h` → `src/x/y.cpp`
5. nothing found → ask: create new (with `#include`), define in the header, or specify a path

## Installation

Neovim ≥ 0.10. No required dependencies (no Treesitter parser needed).

**lazy.nvim / LazyVim**

```lua
return {
  {
    "drook207/qt-assist.nvim",
    -- local checkout instead: dir = "~/Projects/qt-assist.nvim",
    name = "qt-assist.nvim",
    ft = { "cpp", "c", "objcpp", "cuda" },
    cmd = { "QtAssist", "QtAssistSwitch" },
    dependencies = {
      -- optional: provide the build directory with compile_commands.json
      { "Civitasv/cmake-tools.nvim", optional = true },
      { "drook207/qmake-tools.nvim", optional = true },
    },
    ---@type QtAssistConfig
    opts = {
      naming = {
        member_prefixes = { "m_", "m", "_" }, -- bool mFoo → foo
        getter = "{name}", -- bool foo()
        bool_getter = nil, -- e.g. "is{Name}"
        setter = "set{Name}", -- void setFoo()
        setter_param = "{name}",
        signal = "{name}Changed", -- void fooChanged()
      },
      property = {
        full = "Q_PROPERTY({type} {name} READ {getter} WRITE {setter} NOTIFY {signal} FINAL)",
      },
      signal = { emit = "emit", keyword = "signals" },
      definitions = "source", -- bodies into the .cpp
      missing_namespace = "create", -- create missing namespaces in the .cpp
      namespace_style = "nested", -- namespace a::b {
      source = { create_missing = "ask" },
      auto_save = false,
    },
    keys = {
      { "<leader>qa", "<cmd>QtAssist<cr>", mode = { "n", "x" }, desc = "Qt Assist: actions" },
      { "<leader>qp", "<cmd>QtAssist property<cr>", desc = "Qt Assist: Q_PROPERTY + member" },
      { "<leader>qg", "<cmd>QtAssist getset<cr>", mode = { "n", "x" }, desc = "Qt Assist: getter/setter" },
      { "<leader>qd", "<cmd>QtAssist define<cr>", desc = "Qt Assist: generate definition" },
      { "<leader>qD", "<cmd>QtAssist define_all<cr>", desc = "Qt Assist: all missing definitions" },
      { "<leader>qm", "<cmd>QtAssist move<cr>", desc = "Qt Assist: move definition to .cpp" },
      { "<leader>qs", "<cmd>QtAssistSwitch<cr>", desc = "Qt Assist: switch header/source" },
    },
  },
}
```

After that, the actions appear in `vim.lsp.buf.code_action()` (default mapping `gra` from
Neovim 0.11) – also in telescope/fzf-lua/actions-preview.

## Commands

| Command | Description |
|---|---|
| `:QtAssist` | selection menu with all actions at the cursor/selection (usable without LSP) |
| `:QtAssist property` | directly "Q_PROPERTY and missing members" (also: `getset`, `getter`, `setter`, `signal`, `property_reset`, `property_const`, `property_members`, `define`, `define_all`, `move`, `declare`) |
| `:'<,'>QtAssist getset` | for all members in the selection |
| `:QtAssistSwitch` | switch between header and source file (uses the same search) |
| `:checkhealth qt-assist` | integrations, found `compile_commands.json` and `.cpp` |

Example mappings:

```lua
vim.keymap.set({ "n", "x" }, "<leader>qa", "<cmd>QtAssist<cr>", { desc = "Qt Assist" })
vim.keymap.set("n", "<leader>qp", "<cmd>QtAssist property<cr>", { desc = "Generate Q_PROPERTY" })
vim.keymap.set("n", "<leader>qd", "<cmd>QtAssist define_all<cr>", { desc = "Missing definitions" })
vim.keymap.set("n", "<leader>qs", "<cmd>QtAssistSwitch<cr>", { desc = "Header/source" })
```

## Configuration

All options with their default values (see `lua/qt-assist/config.lua`):

```lua
require("qt-assist").setup({
  naming = {
    -- mFoo / m_foo / _foo / foo_ → base name "foo"
    member_prefixes = { "m_", "m", "_" },   -- "m" only before uppercase letters (mode stays mode)
    member_suffixes = { "_" },
    member = "m{Name}",                     -- new member variable from Q_PROPERTY
    getter = "{name}",                      -- bool foo()
    bool_getter = nil,                      -- e.g. "is{Name}" → bool isFoo()
    setter = "set{Name}",                   -- void setFoo()
    setter_param = "{name}",                -- void setFoo(bool foo)   (Qt Creator: "new{Name}")
    signal = "{name}Changed",               -- void fooChanged()
    reset = "reset{Name}",
  },
  property = {
    full     = "Q_PROPERTY({type} {name} READ {getter} WRITE {setter} NOTIFY {signal} FINAL)",
    reset    = "Q_PROPERTY({type} {name} READ {getter} WRITE {setter} RESET {reset} NOTIFY {signal} FINAL)",
    constant = "Q_PROPERTY({type} {name} READ {getter} CONSTANT FINAL)",
    placement = "after_qobject",            -- or "private" (like Qt Creator)
  },
  getter = { const = true, attributes = "", return_by_const_ref = false },
  setter = {
    as_slot = false,                        -- Setter under "public slots:"
    body = { "if ({compare})", "{indent}return;", "{member} = {param};", "{notify}" },
    compare = "{member} == {param}",
    fuzzy_compare = "qFuzzyCompare({member}, {param})",
    move_types = { "std::unique_ptr" },
  },
  signal = { with_value = false, keyword = "signals", emit = "emit" },
  value_types = { "Pointer", "optional", "unique_ptr", "int", "long", "char", "real", ... },

  definitions = "source",                   -- "source" | "header" | "inline"
  inline_getters = false,                   -- getters always directly in the class
  missing_namespace = "create",             -- "create" | "qualify" | "using"
  namespace_style = "nested",               -- "nested" (a::b) | "separate"
  namespace_close_comment = true,           -- } // namespace a::b
  brace_on_new_line = true,
  empty_body = {},                          -- content of new empty bodies, e.g. { "// TODO" }
  blank_lines_between = 1,
  indent = nil,                             -- nil = automatic, number = spaces, "\t"

  source = {
    extensions = { "cpp", "cc", "cxx", "c++", "C" },
    header_extensions = { "h", "hpp", "hh", "hxx", "h++", "H" },
    search_dirs = { ".", "../src", "../source", "../Source", "src", "../../src" },
    use_clangd = true,
    use_compile_commands = true,
    compile_commands = nil,                 -- fixed path or function(bufnr) → path
    create_missing = "ask",                 -- true | false | "ask"
  },

  auto_save = false,                        -- save modified files
  jump_to_definition = false,               -- jump to the .cpp after generating
  lsp = { enabled = true, filetypes = { "cpp", "c", "objcpp", "cuda" }, name = "qt-assist" },
  on_generated = nil,                       -- function(info) – e.g. call clang-format
})
```

### Placeholders in patterns

`{name}` base name (`isValid`), `{Name}` (`IsValid`), `{NAME}`, `{snake}` (`is_valid`), `{type}`,
`{member}`, `{class}`; in property/setter templates additionally `{getter}`, `{setter}`, `{signal}`,
`{reset}`, `{param}`, `{compare}`, `{emit}`, `{indent}`. Each pattern may also be a function:

```lua
naming = {
  getter = function(c) return c.type == "bool" and ("is" .. c.Name) or c.name end,
}
```

### Example: Qt Creator style

```lua
require("qt-assist").setup({
  naming = { setter_param = "new{Name}", member = "m_{name}" },
  property = { placement = "private" },
  signal = { emit = "emit", keyword = "signals" },
})
```

### Formatting after generation

```lua
on_generated = function(info)
  for _, buf in ipairs({ info.header, info.source }) do
    if buf then
      vim.api.nvim_buf_call(buf, function() pcall(vim.lsp.buf.format, { name = "clangd" }) end)
    end
  end
end,
```

## Interaction with other plugins

- **clangd** remains responsible for diagnostics, "Define Outline", includes, etc. – qt-assist only adds
  what clangd cannot do (getters/setters/Q_PROPERTY are not available there; "Create function body
  out-of-line" for pure declarations only from clangd 22, and without creating missing namespaces).
- **cmake-tools.nvim / qmake-tools.nvim** provide the build directory from which the
  `compile_commands.json` is read.
- No Treesitter needed: the custom, Qt-aware parser understands `Q_OBJECT`, `signals:`,
  `public slots:`, `Q_PROPERTY(...)`, `Q_INVOKABLE`, export macros, etc., where the
  C++ Treesitter parser often produces ERROR nodes.

## Tests

```sh
nvim --headless -u NONE -l tests/run.lua
TEST_FILTER=Namespace nvim --headless -u NONE -l tests/run.lua
```
