-- Adversariale Randfälle mit realistischem Qt-Code
local T = _G.T

-- Fehler in collect() nicht verschlucken, sondern sichtbar machen
local function case(name, fn)
  T.case("edge: " .. name, function()
    local A = require("qt-assist.actions")
    local orig = A.collect
    A.collect = function(b, l1, l2)
      return A._collect(b, l1, l2 or l1)
    end
    local ok, err = xpcall(fn, debug.traceback)
    A.collect = orig
    if not ok then
      error(err, 0)
    end
  end)
end

local function titles(path, pat, pat2)
  return vim.tbl_map(function(a)
    return a.title
  end, T.actions(path, pat, pat2))
end

local function no_title(path, pat, needle, pat2)
  for _, t in ipairs(titles(path, pat, pat2)) do
    if t:find(needle, 1, true) then
      error("Aktion unerwartet angeboten: " .. t, 2)
    end
  end
end

local function count(path, needle)
  local txt = T.text(path)
  local n, i = 0, 1
  while true do
    local s, e = txt:find(needle, i, true)
    if not s then
      return n
    end
    n, i = n + 1, e + 1
  end
end

-- 1 ----------------------------------------------------------------------
case("Export-Makro, final, Mehrfachvererbung im Klassenkopf", function()
  local dir = T.project({
    ["f.h"] = {
      "class MYLIB_EXPORT Foo final : public QObject, public QQmlParserStatus",
      "{",
      "    Q_OBJECT",
      "    QML_ELEMENT",
      "    Q_INTERFACES(QQmlParserStatus)",
      "public:",
      "    explicit Foo(QObject *parent = nullptr);",
      "private:",
      "    int mCount = 0;",
      "};",
    },
    ["f.cpp"] = { '#include "f.h"', "", "Foo::Foo(QObject *parent)", "    : QObject(parent)", "{", "}" },
  })
  T.run(dir .. "/f.h", "int mCount", "Getter und Setter")
  T.has(dir .. "/f.h", "    int count() const;\n    void setCount(int count);")
  T.has(dir .. "/f.cpp", "int Foo::count() const\n{\n    return mCount;\n}")
  T.lacks(dir .. "/f.cpp", "MYLIB_EXPORT")
  T.lacks(dir .. "/f.cpp", "final")
end)

-- 2 ----------------------------------------------------------------------
case("Doc-Kommentare zwischen Membern; Einfügen nicht im Kommentar", function()
  local dir = T.project({
    ["d.h"] = {
      "class Doc : public QObject",
      "{",
      "    Q_OBJECT",
      "public:",
      "    /**",
      "     * @brief Konstruktor",
      "     */",
      "    Doc();",
      "    /// Name des Objekts",
      "    QString name() const;",
      "private:",
      "    /// Der Wert",
      "    int mValue; ///< inline doc",
      "    /* Block */ bool mFlag;",
      "};",
    },
    ["d.cpp"] = { '#include "d.h"', "", "Doc::Doc() {}", "", "QString Doc::name() const { return {}; }" },
  })
  T.run(dir .. "/d.h", "int mValue", "Getter und Setter")
  T.has(dir .. "/d.h", "    QString name() const;\n    int value() const;\n    void setValue(int value);\nprivate:")
  T.has(dir .. "/d.cpp", "int Doc::value() const")
  T.run(dir .. "/d.h", "bool mFlag", "Getter und Setter")
  T.has(dir .. "/d.h", "bool flag() const;")
  T.has(dir .. "/d.cpp", "void Doc::setFlag(bool flag)")
end)

-- 3 ----------------------------------------------------------------------
case("Q_OBJECT direkt gefolgt von Membern ohne Access-Specifier (private)", function()
  local dir = T.project({
    ["o.h"] = {
      "class O : public QObject",
      "{",
      "    Q_OBJECT",
      "    QString mTitle;",
      "public:",
      "    O();",
      "};",
    },
    ["o.cpp"] = { '#include "o.h"' },
  })
  T.run(dir .. "/o.h", "QString mTitle", "Getter und Setter")
  -- Getter/Setter müssen in den public-Bereich, nicht hinter Q_OBJECT (private)
  T.has(dir .. "/o.h", "public:\n    O();\n    QString title() const;\n    void setTitle(const QString &title);\n};")
end)

-- 4 ----------------------------------------------------------------------
case("public Q_SLOTS / Q_SIGNALS / private slots: Signale/Slots bekommen keine Definition", function()
  local dir = T.project({
    ["s.h"] = {
      "class S : public QObject",
      "{",
      "    Q_OBJECT",
      "public:",
      "    S();",
      "public Q_SLOTS:",
      "    void refresh();",
      "Q_SIGNALS:",
      "    void changed(int v);",
      "private slots:",
      "    void onTimer();",
      "signals:",
      "    void other();",
      "};",
    },
    ["s.cpp"] = { '#include "s.h"' },
  })
  T.run(dir .. "/s.h", "S();", "Alle fehlenden Definitionen")
  T.has(dir .. "/s.cpp", "void S::refresh()\n{\n}")
  T.has(dir .. "/s.cpp", "void S::onTimer()\n{\n}")
  T.lacks(dir .. "/s.cpp", "S::changed")
  T.lacks(dir .. "/s.cpp", "S::other")
  no_title(dir .. "/s.h", "void changed", "Definition für")
end)

-- 5 ----------------------------------------------------------------------
case("Q_DISABLE_COPY / Q_DECLARE_PRIVATE / Q_ENUM / Q_FLAGS stören nicht", function()
  local dir = T.project({
    ["m.h"] = {
      "class M : public QObject",
      "{",
      "    Q_OBJECT",
      "    Q_DISABLE_COPY(M)",
      "    Q_DECLARE_PRIVATE(M)",
      "public:",
      "    enum Kind { A, B };",
      "    Q_ENUM(Kind)",
      "    enum Opt { X = 1, Y = 2 };",
      "    Q_DECLARE_FLAGS(Opts, Opt)",
      "    Q_FLAGS(Opts)",
      "    M();",
      "private:",
      "    Kind mKind;",
      "};",
    },
    ["m.cpp"] = { '#include "m.h"' },
  })
  T.run(dir .. "/m.h", "Kind mKind", "Q_PROPERTY und fehlende Member")
  T.has(dir .. "/m.h", "Q_PROPERTY(Kind kind READ kind WRITE setKind NOTIFY kindChanged FINAL)")
  T.has(dir .. "/m.cpp", "M::Kind M::kind() const")
  T.has(dir .. "/m.cpp", "void M::setKind(Kind kind)")
  T.lacks(dir .. "/m.cpp", "M::Q_")
end)

-- 6 ----------------------------------------------------------------------
case("Template-Membertypen (verschachtelte >>, std::function)", function()
  local dir = T.project({
    ["t.h"] = {
      "class Tt",
      "{",
      "public:",
      "    Tt();",
      "private:",
      "    QHash<QString, QList<int>> mMap;",
      "    std::function<void(int)> mCallback;",
      "};",
    },
    ["t.cpp"] = { '#include "t.h"' },
  })
  T.run(dir .. "/t.h", "mMap", "Getter und Setter", "mCallback")
  T.has(dir .. "/t.h", "QHash<QString, QList<int>> map() const;")
  T.has(dir .. "/t.h", "void setMap(const QHash<QString, QList<int>> &map);")
  T.has(dir .. "/t.h", "std::function<void(int)> callback() const;")
  T.has(dir .. "/t.h", "void setCallback(const std::function<void(int)> &callback);")
  T.has(dir .. "/t.cpp", "QHash<QString, QList<int>> Tt::map() const")
end)

-- 7 ----------------------------------------------------------------------
case("const-Member: kein Setter", function()
  local dir = T.project({
    ["c.h"] = { "class C {", "public:", "    C();", "private:", "    const int mId;", "    int const mOther;", "};" },
    ["c.cpp"] = { '#include "c.h"' },
  })
  no_title(dir .. "/c.h", "const int mId", "Setter")
  no_title(dir .. "/c.h", "int const mOther", "Setter")
end)

-- 8 ----------------------------------------------------------------------
case("Statische Member: static Getter, kein const", function()
  local dir = T.project({
    ["st.h"] = { "class St {", "public:", "    St();", "private:", "    static int mCount;", "};" },
    ["st.cpp"] = { '#include "st.h"', "", "int St::mCount = 0;" },
  })
  T.run(dir .. "/st.h", "mCount", "Getter und Setter")
  T.has(dir .. "/st.h", "static int count();")
  T.has(dir .. "/st.cpp", "int St::count()\n{")
  T.lacks(dir .. "/st.cpp", "static int St::")
  T.lacks(dir .. "/st.cpp", "int St::count() const")
  -- Aktion heißt "Getter und Setter", Qt Creator erzeugt auch statische Setter
  T.has(dir .. "/st.h", "static void setCount(int count);")
end)

-- 9 ----------------------------------------------------------------------
case("Zeiger- und Referenzmember", function()
  local dir = T.project({
    ["p.h"] = { "class P {", "public:", "    P();", "private:", "    QWidget* mWidget;", "    const QString *mText;", "};" },
    ["p.cpp"] = { '#include "p.h"' },
  })
  T.run(dir .. "/p.h", "mWidget", "Getter und Setter", "mText")
  T.has(dir .. "/p.h", "void setWidget(QWidget *widget);")
  T.has(dir .. "/p.h", "void setText(const QString *text);")
  T.lacks(dir .. "/p.h", "const QString *&")
end)

-- 10 ---------------------------------------------------------------------
case("Verschachtelte Klasse: Definition Outer::Inner::f", function()
  local dir = T.project({
    ["n.h"] = {
      "class Outer {",
      "public:",
      "    class Inner {",
      "    public:",
      "        enum State { On, Off };",
      "        State state() const;",
      "        void reset();",
      "    };",
      "    Outer();",
      "};",
    },
    ["n.cpp"] = { '#include "n.h"' },
  })
  T.run(dir .. "/n.h", "State state()", "Alle fehlenden Definitionen")
  T.has(dir .. "/n.cpp", "Outer::Inner::State Outer::Inner::state() const\n{\n}")
  T.has(dir .. "/n.cpp", "void Outer::Inner::reset()\n{\n}")
  T.lacks(dir .. "/n.cpp", "Outer::Outer()")
end)

-- 11 ---------------------------------------------------------------------
case("Operatoren", function()
  local dir = T.project({
    ["op.h"] = {
      "class Op {",
      "public:",
      "    bool operator==(const Op &other) const;",
      "    bool operator<(const Op &o) const;",
      "    int operator()(int x);",
      "    Op &operator=(const Op &o);",
      "    explicit operator bool() const;",
      "};",
    },
    ["op.cpp"] = { '#include "op.h"' },
  })
  T.run(dir .. "/op.h", "operator==", "Alle fehlenden Definitionen")
  T.has(dir .. "/op.cpp", "bool Op::operator==(const Op &other) const\n{\n}")
  T.has(dir .. "/op.cpp", "bool Op::operator<(const Op &o) const\n{\n}")
  T.has(dir .. "/op.cpp", "int Op::operator()(int x)\n{\n}")
  T.has(dir .. "/op.cpp", "Op &Op::operator=(const Op &o)\n{\n}")
  T.has(dir .. "/op.cpp", "Op::operator bool() const\n{\n}")
  T.lacks(dir .. "/op.cpp", "explicit")
end)

-- 12 ---------------------------------------------------------------------
case("= default / = delete / pure virtual bekommen keine Definition", function()
  local dir = T.project({
    ["v.h"] = {
      "class V {",
      "public:",
      "    V() = default;",
      "    V(const V &) = delete;",
      "    virtual ~V();",
      "    virtual void run() = 0;",
      "    virtual void stop() const = 0;",
      "    void go();",
      "};",
    },
    ["v.cpp"] = { '#include "v.h"' },
  })
  T.run(dir .. "/v.h", "void go", "Alle fehlenden Definitionen")
  T.has(dir .. "/v.cpp", "V::~V()\n{\n}")
  T.has(dir .. "/v.cpp", "void V::go()\n{\n}")
  T.lacks(dir .. "/v.cpp", "V::run")
  T.lacks(dir .. "/v.cpp", "V::stop")
  T.lacks(dir .. "/v.cpp", "V::V(")
  no_title(dir .. "/v.h", "V() = default", "Definition für")
  no_title(dir .. "/v.h", "void run()", "Definition für")
end)

-- 13 ---------------------------------------------------------------------
case("Konstruktor mit Init-Liste und Default-Arg -> Definition ohne Default", function()
  local dir = T.project({
    ["k.h"] = { "class K : public QObject {", "    Q_OBJECT", "public:", "    explicit K(int a = 1, QObject *parent = nullptr);", "};" },
    ["k.cpp"] = { '#include "k.h"' },
  })
  T.run(dir .. "/k.h", "explicit K(", "Definition für K()")
  T.has(dir .. "/k.cpp", "K::K(int a, QObject *parent)\n{\n}")
end)

-- 14 ---------------------------------------------------------------------
case("Einfügeposition: nach der Definition der vorherigen Deklaration", function()
  local dir = T.project({
    ["o.h"] = { "class Ord {", "public:", "    void a();", "    void b();", "    void c();", "};" },
    ["o.cpp"] = {
      '#include "o.h"', "", "void Ord::c()", "{", "}", "", "void Ord::a()", "{", "}", "", "// Ende",
    },
  })
  T.run(dir .. "/o.h", "void b", "Definition für b()")
  T.has(dir .. "/o.cpp", "void Ord::a()\n{\n}\n\nvoid Ord::b()\n{\n}\n\n// Ende")
end)

-- 15 ---------------------------------------------------------------------
case("Verschachtelte namespace-Blöcke in der .cpp", function()
  local dir = T.project({
    ["nn.h"] = { "namespace a {", "namespace b {", "class N {", "public:", "    void x();", "    void y();", "};", "}", "}" },
    ["nn.cpp"] = {
      '#include "nn.h"', "", "namespace a {", "namespace b {", "", "void N::x()", "{", "}", "", "} // namespace b", "} // namespace a",
    },
  })
  T.run(dir .. "/nn.h", "void y", "Definition für y()")
  T.has(dir .. "/nn.cpp", "void N::x()\n{\n}\n\nvoid N::y()\n{\n}\n\n} // namespace b")
  T.lacks(dir .. "/nn.cpp", "a::b::N::y")
  T.eq(count(dir .. "/nn.cpp", "namespace a {"), 1, "kein zweiter namespace-Block")
end)

-- 16 ---------------------------------------------------------------------
case("using namespace in .cpp", function()
  local dir = T.project({
    ["u.h"] = { "namespace lib {", "class U {", "public:", "    void x();", "};", "}" },
    ["u.cpp"] = { '#include "u.h"', "", "using namespace lib;", "", "void U::w() {}" },
  })
  T.run(dir .. "/u.h", "void x", "Definition für x()")
  T.has(dir .. "/u.cpp", "void U::x()\n{\n}")
  T.lacks(dir .. "/u.cpp", "namespace lib {")
end)

-- 17 ---------------------------------------------------------------------
case("Anonymer Namespace in der .cpp: nicht hineinschreiben", function()
  local dir = T.project({
    ["an.h"] = { "class An {", "public:", "    void x();", "};" },
    ["an.cpp"] = { '#include "an.h"', "", "namespace {", "int helper() { return 1; }", "}", "" },
  })
  T.run(dir .. "/an.h", "void x", "Definition für x()")
  T.has(dir .. "/an.cpp", "namespace {\nint helper() { return 1; }\n}\n")
  local txt = T.text(dir .. "/an.cpp")
  local ns_end = txt:find("}\n", txt:find("helper"), true)
  local def = txt:find("void An::x()", 1, true)
  assert(def and def > ns_end, "Definition liegt im anonymen Namespace:\n" .. txt)
end)

-- 18 ---------------------------------------------------------------------
case("Klassentemplate: Definition im Header, nicht in .cpp", function()
  local dir = T.project({
    ["tp.h"] = { "template <typename T>", "class Box {", "public:", "    T get() const;", "private:", "    T mValue;", "};" },
    ["tp.cpp"] = { '#include "tp.h"' },
  })
  no_title(dir .. "/tp.h", "T get", "in tp.cpp")
  T.run(dir .. "/tp.h", "T get", "außerhalb der Klasse")
  T.has(dir .. "/tp.h", "template <typename T>\nT Box<T>::get() const\n{\n}")
  T.run(dir .. "/tp.h", "T mValue", "Getter und Setter")
  T.lacks(dir .. "/tp.cpp", "Box")
  T.has(dir .. "/tp.h", "void setValue(const T &value);")
end)

-- 19 ---------------------------------------------------------------------
case("Zwei Aktionen hintereinander (Cache-Invalidierung)", function()
  local dir = T.project({
    ["two.h"] = { "class Two {", "public:", "    void a();", "    void b();", "private:", "    int mX;", "};" },
    ["two.cpp"] = { '#include "two.h"' },
  })
  T.run(dir .. "/two.h", "void a", "Definition für a()")
  no_title(dir .. "/two.h", "void a", "Definition für a()")
  T.run(dir .. "/two.h", "int mX", "Getter und Setter")
  -- Zeilen haben sich verschoben; b() muss trotzdem korrekt gefunden werden
  T.run(dir .. "/two.h", "void b", "Definition für b()")
  T.eq(count(dir .. "/two.cpp", "void Two::a()"), 1)
  T.eq(count(dir .. "/two.cpp", "void Two::b()"), 1)
  T.eq(count(dir .. "/two.cpp", "int Two::x() const"), 1)
  -- Alle fehlenden: jetzt nichts mehr übrig
  no_title(dir .. "/two.h", "void a", "Alle fehlenden")
end)

-- 20 ---------------------------------------------------------------------
case("Visueller Bereich über mehrere Member inkl. Kommentarzeile", function()
  local dir = T.project({
    ["r.h"] = {
      "class R {",
      "public:",
      "    R();",
      "private:",
      "    int mA;",
      "    // Trenner",
      "    QString mB;",
      "    bool mC;",
      "};",
    },
    ["r.cpp"] = { '#include "r.h"' },
  })
  T.run(dir .. "/r.h", "int mA", "Getter und Setter für 3 Member", "bool mC")
  T.has(dir .. "/r.h", "    R();\n    int a() const;\n    void setA(int a);\n    QString b() const;\n    void setB(const QString &b);\n    bool c() const;\n    void setC(bool c);\nprivate:")
end)

-- 21 ---------------------------------------------------------------------
case("#ifdef im Klassenrumpf: nichts zwischen #ifdef/#endif einfügen", function()
  local dir = T.project({
    ["if.h"] = {
      "class If {",
      "public:",
      "    If();",
      "#ifdef HAS_EXTRA",
      "    void extra();",
      "#endif",
      "private:",
      "    int mV;",
      "};",
    },
    ["if.cpp"] = { '#include "if.h"' },
  })
  T.run(dir .. "/if.h", "int mV", "Getter und Setter")
  local txt = T.text(dir .. "/if.h")
  local s, e = txt:find("#ifdef HAS_EXTRA.-#endif")
  local seg = txt:sub(s, e)
  assert(not seg:find("int v() const", 1, true), "Getter innerhalb #ifdef eingefügt:\n" .. txt)
  T.has(dir .. "/if.h", "int v() const;")
end)

-- 22 ---------------------------------------------------------------------
case("Tabs als Einrückung werden übernommen", function()
  local dir = T.project({
    ["tab.h"] = { "class Tab {", "public:", "\tTab();", "private:", "\tint mV;", "};" },
    ["tab.cpp"] = { '#include "tab.h"' },
  })
  T.run(dir .. "/tab.h", "int mV", "Getter und Setter")
  T.has(dir .. "/tab.h", "\tTab();\n\tint v() const;\n\tvoid setV(int v);")
end)

-- 23 ---------------------------------------------------------------------
case("Inline-Definition mit Kommentar und verschachtelten Klammern verschieben", function()
  local dir = T.project({
    ["mv.h"] = {
      "class Mv {",
      "public:",
      "    int f(int a = 3) const { // kommentar }",
      "        if (a) { return 1; }",
      "        return \"}\"[0];",
      "    }",
      "    void g();",
      "};",
    },
    ["mv.cpp"] = { '#include "mv.h"' },
  })
  T.run(dir .. "/mv.h", "int f(", "verschieben")
  T.has(dir .. "/mv.h", "    int f(int a = 3) const;\n    void g();")
  T.has(dir .. "/mv.cpp", "int Mv::f(int a) const\n{")
  T.has(dir .. "/mv.cpp", "return \"}\"[0];")
end)

-- 24 ---------------------------------------------------------------------
case("Deklaration aus .cpp in Klasse in namespace ergänzen (namespace-Block)", function()
  local dir = T.project({
    ["dn.h"] = { "namespace app {", "class Dn {", "public:", "    Dn();", "private:", "    int mX;", "};", "}" },
    ["dn.cpp"] = { '#include "dn.h"', "", "namespace app {", "", "void Dn::helper(const QString &s, int n)", "{", "}", "", "}" },
  })
  T.run(dir .. "/dn.cpp", "Dn::helper", "Private Deklaration")
  T.has(dir .. "/dn.h", "private:\n    int mX;\n    void helper(const QString &s, int n);\n};")
end)

-- 25 ---------------------------------------------------------------------
case("Deklaration für Outer::Inner aus .cpp", function()
  local dir = T.project({
    ["oi.h"] = { "class Outer {", "public:", "    struct Inner {", "        int x;", "    };", "};" },
    ["oi.cpp"] = { '#include "oi.h"', "", "int Outer::Inner::twice() const", "{", "    return x * 2;", "}" },
  })
  T.run(dir .. "/oi.cpp", "Outer::Inner::twice", "Öffentliche Deklaration")
  T.has(dir .. "/oi.h", "    struct Inner {\n        int x;\n        int twice() const;\n    };")
end)

-- 26 ---------------------------------------------------------------------
case("Q_PROPERTY mit MEMBER/CONSTANT generiert nichts Unsinniges", function()
  local dir = T.project({
    ["qp.h"] = {
      "class Qp : public QObject {",
      "    Q_OBJECT",
      "    Q_PROPERTY(QList<int> values READ values NOTIFY valuesChanged)",
      "    Q_PROPERTY(int id READ id CONSTANT)",
      "public:",
      "    Qp();",
      "};",
    },
    ["qp.cpp"] = { '#include "qp.h"' },
  })
  T.run(dir .. "/qp.h", "QList<int> values", "Fehlende Member für Q_PROPERTY", "int id READ")
  T.has(dir .. "/qp.h", "QList<int> values() const;")
  T.has(dir .. "/qp.h", "int id() const;")
  T.lacks(dir .. "/qp.h", "setValues")
  T.lacks(dir .. "/qp.h", "setId")
  T.lacks(dir .. "/qp.h", "idChanged")
  T.has(dir .. "/qp.h", "void valuesChanged();")
  T.has(dir .. "/qp.cpp", "QList<int> Qp::values() const\n{\n    return mValues;\n}")
end)

-- 27 ---------------------------------------------------------------------
case("CRLF-Dateien: keine gemischten Zeilenenden / kein \\r im Namen", function()
  local dir = T.project({
    ["cr.h"] = { "class Cr {\r", "public:\r", "    void x();\r", "private:\r", "    int mV;\r", "};\r" },
    ["cr.cpp"] = { '#include "cr.h"\r' },
  })
  T.run(dir .. "/cr.h", "int mV", "Getter und Setter")
  T.lacks(dir .. "/cr.h", "\r(")
  T.lacks(dir .. "/cr.cpp", "\r(")
  T.has(dir .. "/cr.cpp", "int Cr::v() const")
end)

-- 28 ---------------------------------------------------------------------
case("Rückgabe mit verschachteltem Enum + Default-Arg mit Template/Komma", function()
  local dir = T.project({
    ["ra.h"] = {
      "class Ra {",
      "public:",
      "    enum class Mode { A, B };",
      "    Mode pick(const QMap<QString, int> &m = QMap<QString, int>(), int n = (1, 2)) const;",
      "    QList<Mode> modes();",
      "};",
    },
    ["ra.cpp"] = { '#include "ra.h"' },
  })
  T.run(dir .. "/ra.h", "Mode pick", "Alle fehlenden Definitionen")
  T.has(dir .. "/ra.cpp", "Ra::Mode Ra::pick(const QMap<QString, int> &m, int n) const\n{\n}")
  T.has(dir .. "/ra.cpp", "QList<Ra::Mode> Ra::modes()\n{\n}")
end)

-- 29 ---------------------------------------------------------------------
case("Array-Member: keine sinnlosen Getter/Setter mit Arraytyp", function()
  local dir = T.project({
    ["ar.h"] = { "class Ar {", "public:", "    Ar();", "private:", "    int mBuf[16];", "};" },
    ["ar.cpp"] = { '#include "ar.h"' },
  })
  for _, t in ipairs(titles(dir .. "/ar.h", "mBuf")) do
    if t:find("Setter", 1, true) then
      T.run(dir .. "/ar.h", "mBuf", t)
      T.lacks(dir .. "/ar.h", "void setBuf(int buf)")
      T.lacks(dir .. "/ar.h", "int buf() const")
      break
    end
  end
end)

-- 30 ---------------------------------------------------------------------
case("Signal mit Changed-Signal existiert bereits -> nicht doppelt", function()
  local dir = T.project({
    ["ex.h"] = {
      "class Ex : public QObject {", "    Q_OBJECT", "public:", "    int value() const;", "Q_SIGNALS:",
      "    void valueChanged();", "private:", "    int mValue;", "};",
    },
    ["ex.cpp"] = { '#include "ex.h"', "", "int Ex::value() const { return mValue; }" },
  })
  T.run(dir .. "/ex.h", "int mValue", "Getter, Setter und Changed-Signal")
  T.eq(count(dir .. "/ex.h", "valueChanged()"), 1)
  T.eq(count(dir .. "/ex.h", "int value() const"), 1)
  T.has(dir .. "/ex.h", "void setValue(int value);")
  T.eq(count(dir .. "/ex.cpp", "Ex::value()"), 1)
end)

-- 31 ---------------------------------------------------------------------
case("struct: Standard-Access public, Brace-Initializer am Member", function()
  local dir = T.project({
    ["sr.h"] = { "struct Sr", "{", "    Sr();", "    QString mName{QStringLiteral(\"x\")};", "    int mN = 4;", "};" },
    ["sr.cpp"] = { '#include "sr.h"' },
  })
  T.run(dir .. "/sr.h", "QString mName", "Getter und Setter")
  T.has(dir .. "/sr.h", "QString name() const;")
  T.has(dir .. "/sr.h", "void setName(const QString &name);")
  T.has(dir .. "/sr.cpp", "QString Sr::name() const\n{\n    return mName;\n}")
  T.lacks(dir .. "/sr.h", "private:\n    QString name() const")
end)

-- 32 ---------------------------------------------------------------------
case("Spezifizierer: noexcept, [[nodiscard]], override final, Trailing Return, Ref-Qualifier", function()
  local dir = T.project({
    ["sp.h"] = {
      "class Sp : public Base {",
      "public:",
      "    [[nodiscard]] int a() const noexcept;",
      "    void b() override final;",
      "    auto c() const -> QString;",
      "    QString d() const &;",
      "    Q_INVOKABLE Q_REQUIRED_RESULT int e(int x = 0);",
      "};",
    },
    ["sp.cpp"] = { '#include "sp.h"' },
  })
  T.run(dir .. "/sp.h", "int a()", "Alle fehlenden Definitionen")
  T.has(dir .. "/sp.cpp", "int Sp::a() const noexcept\n{\n}")
  T.has(dir .. "/sp.cpp", "void Sp::b()\n{\n}")
  T.has(dir .. "/sp.cpp", "auto Sp::c() const -> QString\n{\n}")
  T.has(dir .. "/sp.cpp", "QString Sp::d() const &\n{\n}")
  T.has(dir .. "/sp.cpp", "int Sp::e(int x)\n{\n}")
  T.lacks(dir .. "/sp.cpp", "override")
  T.lacks(dir .. "/sp.cpp", "Q_INVOKABLE")
end)

-- 33 ---------------------------------------------------------------------
case("Signale am Klassenende hinter #endif nicht in #ifdef einfügen", function()
  local dir = T.project({
    ["se.h"] = {
      "class Se : public QObject {",
      "    Q_OBJECT",
      "public:",
      "    Se();",
      "private:",
      "    int mV;",
      "#ifdef DEBUG",
      "    int mDbg;",
      "#endif",
      "};",
    },
    ["se.cpp"] = { '#include "se.h"' },
  })
  T.run(dir .. "/se.h", "int mV", "Getter, Setter und Changed-Signal")
  local txt = T.text(dir .. "/se.h")
  local seg = txt:match("#ifdef DEBUG.-#endif")
  assert(not seg:find("vChanged", 1, true), "Signal in #ifdef eingefügt:\n" .. txt)
  T.has(dir .. "/se.h", "void vChanged();")
end)

-- 34 ---------------------------------------------------------------------
case("Verschieben einer Inline-Definition in Klasse innerhalb von namespace", function()
  local dir = T.project({
    ["mn.h"] = { "namespace ns {", "class Mn {", "public:", "    int v() const { return 1; }", "};", "} // namespace ns" },
    ["mn.cpp"] = { '#include "mn.h"', "", "namespace ns {", "", "} // namespace ns" },
  })
  T.run(dir .. "/mn.h", "int v()", "verschieben")
  T.has(dir .. "/mn.h", "    int v() const;")
  T.has(dir .. "/mn.cpp", "namespace ns {\n\nint Mn::v() const\n{\n    return 1;\n}\n\n} // namespace ns")
end)

-- 35 ---------------------------------------------------------------------
case("Zeiger auf const ist kein const-Member", function()
  local dir = T.project({
    ["pc.h"] = { "class Pc {", "public:", "    Pc();", "private:", "    const QString *mText;", "};" },
    ["pc.cpp"] = { '#include "pc.h"' },
  })
  T.run(dir .. "/pc.h", "mText", "Getter und Setter")
  T.has(dir .. "/pc.h", "    const QString *text() const;\n    void setText(const QString *text);")
end)
