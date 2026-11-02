# qt-assist.nvim

Qt-Creator-Refactorings für Neovim: Getter, Setter, Changed-Signal und
`Q_PROPERTY` aus einer Membervariable erzeugen, Funktionsdefinitionen aus dem
Header in die passende `.cpp` schreiben (inkl. fehlender Namespaces) – als ganz
normale **Code-Actions** (`vim.lsp.buf.code_action()`), direkt neben denen von clangd.

```cpp
// Header – Cursor auf mIsValid, Code-Action
// "Q_PROPERTY und fehlende Member für mIsValid erzeugen"
class Person : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool isValid READ isValid WRITE setIsValid NOTIFY isValidChanged FINAL)  // neu
public:
    bool isValid() const;                // neu
    void setIsValid(bool isValid);       // neu
signals:
    void isValidChanged();               // neu
private:
    bool mIsValid = false;
};
```

```cpp
// person.cpp – automatisch, im richtigen Namespace
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

## Funktionen

| Cursor auf | Code-Actions |
|---|---|
| Membervariable (oder Visual-Auswahl über mehrere) | Getter und Setter · Getter · Setter · Getter, Setter und Changed-Signal · **Q_PROPERTY und fehlende Member** · Q_PROPERTY mit Reset · konstante Q_PROPERTY |
| `Q_PROPERTY(...)`-Zeile | Fehlende Member erzeugen (Membervariable, READ, WRITE, NOTIFY, RESET) |
| Funktionsdeklaration im Header | Definition in `foo.cpp` · außerhalb der Klasse (inline im Header) · in der Klasse |
| Inline-Definition in der Klasse | Definition nach `foo.cpp` verschieben (inkl. Initialisierungsliste) |
| irgendwo in der Klasse | Alle fehlenden Definitionen in `foo.cpp` erzeugen |
| Definition in der `.cpp` ohne Deklaration | Öffentliche/geschützte/private Deklaration bzw. public slot im Header erzeugen |

Dabei wird beachtet:

- **Bereits Vorhandenes** wird nicht doppelt erzeugt (Getter, Setter, Signal, Property, Definitionen –
  auch wenn sie in der `.cpp` voll qualifiziert oder per `using namespace` stehen).
- **Abschnitte**: Getter/Setter in `public:`, Signale in `signals:`/`Q_SIGNALS:`; fehlende Abschnitte
  werden am Klassenende angelegt, `Q_OBJECT` wird bei Bedarf ergänzt.
- **Parameter**: Klassen per `const T &`, eingebaute Typen, Zeiger, Enums der Klasse per Wert
  (Liste wie in Qt Creator, konfigurierbar). Fließkommazahlen werden mit `qFuzzyCompare` verglichen,
  `std::unique_ptr` per `std::move` zugewiesen.
- **Definitionen**: Default-Argumente, `virtual`, `static`, `override`, `Q_INVOKABLE` usw. entfallen;
  verschachtelte Typen im Rückgabetyp werden qualifiziert (`Person::State Person::state() const`);
  Pure-Virtual, `= default`/`= delete` und Signale bekommen keine Definition.
- **Reihenfolge**: neue Definitionen landen hinter der Definition der vorher deklarierten Funktion
  (wie in Qt Creator) und übernehmen deren Schreibweise (`Person::` vs. `app::model::Person::`).
- **Namespaces**: fehlende Namespace-Blöcke werden in der `.cpp` angelegt (`namespace a::b {` oder
  verschachtelt), alternativ voll qualifiziert oder per `using namespace` – siehe `missing_namespace`.
- **Templates**: Klassen- und Member-Templates werden im Header definiert (mit `template <…>`).
- Einrückung (Spaces/Tabs, Breite) wird aus der Datei übernommen.

## Wie die `.cpp` gefunden wird

1. gleiches Verzeichnis, gleicher Name (`foo.h` → `foo.cpp`, `.cc`, `.cxx`, …)
2. clangd: `textDocument/switchSourceHeader`
3. **`compile_commands.json`** – Quelldatei mit gleichem Namen, die dem Header am nächsten liegt.
   Die Datei wird gesucht über:
   - [cmake-tools.nvim](https://github.com/Civitasv/cmake-tools.nvim) (`get_build_directory()`)
   - qmake-tools.nvim (Build-Verzeichnis der aktiven Konfiguration)
   - `--compile-commands-dir` bzw. Root-Verzeichnis des laufenden clangd
   - Suche aufwärts (auch in `build*/`)
4. Suchpfade (`../src`, `src`, …) und `include/x/y.h` → `src/x/y.cpp`
5. nichts gefunden → nachfragen: neu anlegen (mit `#include`), im Header definieren oder Pfad angeben

## Installation

Neovim ≥ 0.10. Keine Pflicht-Abhängigkeiten (kein Treesitter-Parser nötig).

**lazy.nvim**

```lua
{
  "dein-name/qt-assist.nvim",
  ft = { "cpp", "c" },
  dependencies = {
    -- optional, für die compile_commands.json:
    -- "Civitasv/cmake-tools.nvim",
    -- "dein-name/qmake-tools.nvim",
  },
  opts = {},
}
```

Danach erscheinen die Aktionen in `vim.lsp.buf.code_action()` (Standard-Mapping `gra` ab
Neovim 0.11) – auch in telescope/fzf-lua/actions-preview.

## Befehle

| Befehl | Beschreibung |
|---|---|
| `:QtAssist` | Auswahlmenü mit allen Aktionen an Cursor/Auswahl (ohne LSP nutzbar) |
| `:QtAssist property` | direkt „Q_PROPERTY und fehlende Member“ (auch: `getset`, `getter`, `setter`, `signal`, `property_reset`, `property_const`, `property_members`, `define`, `define_all`, `move`, `declare`) |
| `:'<,'>QtAssist getset` | für alle Member in der Auswahl |
| `:QtAssistSwitch` | zwischen Header und Quelldatei wechseln (nutzt dieselbe Suche) |
| `:checkhealth qt-assist` | Integrationen, gefundene `compile_commands.json` und `.cpp` |

Beispiel-Mappings:

```lua
vim.keymap.set({ "n", "x" }, "<leader>qa", "<cmd>QtAssist<cr>", { desc = "Qt Assist" })
vim.keymap.set("n", "<leader>qp", "<cmd>QtAssist property<cr>", { desc = "Q_PROPERTY erzeugen" })
vim.keymap.set("n", "<leader>qd", "<cmd>QtAssist define_all<cr>", { desc = "Fehlende Definitionen" })
vim.keymap.set("n", "<leader>qs", "<cmd>QtAssistSwitch<cr>", { desc = "Header/Quelle" })
```

## Konfiguration

Alle Optionen mit Standardwerten (siehe `lua/qt-assist/config.lua`):

```lua
require("qt-assist").setup({
  naming = {
    -- mFoo / m_foo / _foo / foo_ → Basisname "foo"
    member_prefixes = { "m_", "m", "_" },   -- "m" nur vor Großbuchstaben (mode bleibt mode)
    member_suffixes = { "_" },
    member = "m{Name}",                     -- neue Membervariable aus Q_PROPERTY
    getter = "{name}",                      -- bool foo()
    bool_getter = nil,                      -- z. B. "is{Name}" → bool isFoo()
    setter = "set{Name}",                   -- void setFoo()
    setter_param = "{name}",                -- void setFoo(bool foo)   (Qt Creator: "new{Name}")
    signal = "{name}Changed",               -- void fooChanged()
    reset = "reset{Name}",
  },
  property = {
    full     = "Q_PROPERTY({type} {name} READ {getter} WRITE {setter} NOTIFY {signal} FINAL)",
    reset    = "Q_PROPERTY({type} {name} READ {getter} WRITE {setter} RESET {reset} NOTIFY {signal} FINAL)",
    constant = "Q_PROPERTY({type} {name} READ {getter} CONSTANT FINAL)",
    placement = "after_qobject",            -- oder "private" (wie Qt Creator)
  },
  getter = { const = true, attributes = "", return_by_const_ref = false },
  setter = {
    as_slot = false,                        -- Setter unter "public slots:"
    body = { "if ({compare})", "{indent}return;", "{member} = {param};", "{notify}" },
    compare = "{member} == {param}",
    fuzzy_compare = "qFuzzyCompare({member}, {param})",
    move_types = { "std::unique_ptr" },
  },
  signal = { with_value = false, keyword = "signals", emit = "emit" },
  value_types = { "Pointer", "optional", "unique_ptr", "int", "long", "char", "real", ... },

  definitions = "source",                   -- "source" | "header" | "inline"
  inline_getters = false,                   -- Getter immer direkt in der Klasse
  missing_namespace = "create",             -- "create" | "qualify" | "using"
  namespace_style = "nested",               -- "nested" (a::b) | "separate"
  namespace_close_comment = true,           -- } // namespace a::b
  brace_on_new_line = true,
  empty_body = {},                          -- Inhalt neuer leerer Rümpfe, z. B. { "// TODO" }
  blank_lines_between = 1,
  indent = nil,                             -- nil = automatisch, Zahl = Spaces, "\t"

  source = {
    extensions = { "cpp", "cc", "cxx", "c++", "C" },
    header_extensions = { "h", "hpp", "hh", "hxx", "h++", "H" },
    search_dirs = { ".", "../src", "../source", "../Source", "src", "../../src" },
    use_clangd = true,
    use_compile_commands = true,
    compile_commands = nil,                 -- fester Pfad oder function(bufnr) → Pfad
    create_missing = "ask",                 -- true | false | "ask"
  },

  auto_save = false,                        -- geänderte Dateien speichern
  jump_to_definition = false,               -- nach dem Erzeugen in die .cpp springen
  lsp = { enabled = true, filetypes = { "cpp", "c", "objcpp", "cuda" }, name = "qt-assist" },
  on_generated = nil,                       -- function(info) – z. B. clang-format aufrufen
})
```

### Platzhalter in Mustern

`{name}` Basisname (`isValid`), `{Name}` (`IsValid`), `{NAME}`, `{snake}` (`is_valid`), `{type}`,
`{member}`, `{class}`; in Property-/Setter-Vorlagen zusätzlich `{getter}`, `{setter}`, `{signal}`,
`{reset}`, `{param}`, `{compare}`, `{emit}`, `{indent}`. Jedes Muster darf auch eine Funktion sein:

```lua
naming = {
  getter = function(c) return c.type == "bool" and ("is" .. c.Name) or c.name end,
}
```

### Beispiel: Qt-Creator-Stil

```lua
require("qt-assist").setup({
  naming = { setter_param = "new{Name}", member = "m_{name}" },
  property = { placement = "private" },
  signal = { emit = "emit", keyword = "signals" },
})
```

### Formatierung nach dem Erzeugen

```lua
on_generated = function(info)
  for _, buf in ipairs({ info.header, info.source }) do
    if buf then
      vim.api.nvim_buf_call(buf, function() pcall(vim.lsp.buf.format, { name = "clangd" }) end)
    end
  end
end,
```

## Zusammenspiel mit anderen Plugins

- **clangd** bleibt für Diagnosen, „Define Outline“, Includes usw. zuständig – qt-assist ergänzt nur,
  was clangd nicht kann (Getter/Setter/Q_PROPERTY gibt es dort nicht; „Create function body
  out-of-line“ für reine Deklarationen erst ab clangd 22, und ohne Anlegen fehlender Namespaces).
- **cmake-tools.nvim / qmake-tools.nvim** liefern das Build-Verzeichnis, aus dem die
  `compile_commands.json` gelesen wird.
- Kein Treesitter nötig: der eigene, Qt-bewusste Parser versteht `Q_OBJECT`, `signals:`,
  `public slots:`, `Q_PROPERTY(...)`, `Q_INVOKABLE`, Export-Makros usw., an denen der
  C++-Treesitter-Parser häufig ERROR-Knoten erzeugt.

## Tests

```sh
nvim --headless -u NONE -l tests/run.lua
TEST_FILTER=Namespace nvim --headless -u NONE -l tests/run.lua
```
