-- Adversarial edge cases with realistic Qt code
local T = _G.T

-- Do not swallow errors in collect(); make them visible
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
      error("Unexpected action offered: " .. t, 2)
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
case("Export macro, final, multiple inheritance in the class head", function()
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
  T.run(dir .. "/f.h", "int mCount", "Getter and setter")
  T.has(dir .. "/f.h", "    int count() const;\n    void setCount(int count);")
  T.has(dir .. "/f.cpp", "int Foo::count() const\n{\n    return mCount;\n}")
  T.lacks(dir .. "/f.cpp", "MYLIB_EXPORT")
  T.lacks(dir .. "/f.cpp", "final")
end)

-- 2 ----------------------------------------------------------------------
case("Doc comments between members; do not insert into a comment", function()
  local dir = T.project({
    ["d.h"] = {
      "class Doc : public QObject",
      "{",
      "    Q_OBJECT",
      "public:",
      "    /**",
      "     * @brief Constructor",
      "     */",
      "    Doc();",
      "    /// Name of the object",
      "    QString name() const;",
      "private:",
      "    /// The value",
      "    int mValue; ///< inline doc",
      "    /* Block */ bool mFlag;",
      "};",
    },
    ["d.cpp"] = { '#include "d.h"', "", "Doc::Doc() {}", "", "QString Doc::name() const { return {}; }" },
  })
  T.run(dir .. "/d.h", "int mValue", "Getter and setter")
  T.has(dir .. "/d.h", "    QString name() const;\n    int value() const;\n    void setValue(int value);\nprivate:")
  T.has(dir .. "/d.cpp", "int Doc::value() const")
  T.run(dir .. "/d.h", "bool mFlag", "Getter and setter")
  T.has(dir .. "/d.h", "bool flag() const;")
  T.has(dir .. "/d.cpp", "void Doc::setFlag(bool flag)")
end)

-- 3 ----------------------------------------------------------------------
case("Q_OBJECT immediately followed by members without an access specifier (private)", function()
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
  T.run(dir .. "/o.h", "QString mTitle", "Getter and setter")
  -- Getters/setters must go in the public section, not behind Q_OBJECT (private)
  T.has(dir .. "/o.h", "public:\n    O();\n    QString title() const;\n    void setTitle(const QString &title);\n};")
end)

-- 4 ----------------------------------------------------------------------
case("public Q_SLOTS / Q_SIGNALS / private slots: signals/slots get no definition", function()
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
  T.run(dir .. "/s.h", "S();", "Generate all missing definitions")
  T.has(dir .. "/s.cpp", "void S::refresh()\n{\n}")
  T.has(dir .. "/s.cpp", "void S::onTimer()\n{\n}")
  T.lacks(dir .. "/s.cpp", "S::changed")
  T.lacks(dir .. "/s.cpp", "S::other")
  no_title(dir .. "/s.h", "void changed", "Generate definition for")
end)

-- 5 ----------------------------------------------------------------------
case("Q_DISABLE_COPY / Q_DECLARE_PRIVATE / Q_ENUM / Q_FLAGS do not interfere", function()
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
  T.run(dir .. "/m.h", "Kind mKind", "Q_PROPERTY and missing members")
  T.has(dir .. "/m.h", "Q_PROPERTY(Kind kind READ kind WRITE setKind NOTIFY kindChanged FINAL)")
  T.has(dir .. "/m.cpp", "M::Kind M::kind() const")
  T.has(dir .. "/m.cpp", "void M::setKind(Kind kind)")
  T.lacks(dir .. "/m.cpp", "M::Q_")
end)

-- 6 ----------------------------------------------------------------------
case("Template member types (nested >>, std::function)", function()
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
  T.run(dir .. "/t.h", "mMap", "Getter and setter", "mCallback")
  T.has(dir .. "/t.h", "QHash<QString, QList<int>> map() const;")
  T.has(dir .. "/t.h", "void setMap(const QHash<QString, QList<int>> &map);")
  T.has(dir .. "/t.h", "std::function<void(int)> callback() const;")
  T.has(dir .. "/t.h", "void setCallback(const std::function<void(int)> &callback);")
  T.has(dir .. "/t.cpp", "QHash<QString, QList<int>> Tt::map() const")
end)

-- 7 ----------------------------------------------------------------------
case("const member: no setter", function()
  local dir = T.project({
    ["c.h"] = { "class C {", "public:", "    C();", "private:", "    const int mId;", "    int const mOther;", "};" },
    ["c.cpp"] = { '#include "c.h"' },
  })
  no_title(dir .. "/c.h", "const int mId", "Setter")
  no_title(dir .. "/c.h", "int const mOther", "Setter")
end)

-- 8 ----------------------------------------------------------------------
case("Static members: static getter, no const", function()
  local dir = T.project({
    ["st.h"] = { "class St {", "public:", "    St();", "private:", "    static int mCount;", "};" },
    ["st.cpp"] = { '#include "st.h"', "", "int St::mCount = 0;" },
  })
  T.run(dir .. "/st.h", "mCount", "Getter and setter")
  T.has(dir .. "/st.h", "static int count();")
  T.has(dir .. "/st.cpp", "int St::count()\n{")
  T.lacks(dir .. "/st.cpp", "static int St::")
  T.lacks(dir .. "/st.cpp", "int St::count() const")
  -- The action is called "Getter and setter"; Qt Creator also generates static setters
  T.has(dir .. "/st.h", "static void setCount(int count);")
end)

-- 9 ----------------------------------------------------------------------
case("Pointer and reference members", function()
  local dir = T.project({
    ["p.h"] = { "class P {", "public:", "    P();", "private:", "    QWidget* mWidget;", "    const QString *mText;", "};" },
    ["p.cpp"] = { '#include "p.h"' },
  })
  T.run(dir .. "/p.h", "mWidget", "Getter and setter", "mText")
  T.has(dir .. "/p.h", "void setWidget(QWidget *widget);")
  T.has(dir .. "/p.h", "void setText(const QString *text);")
  T.lacks(dir .. "/p.h", "const QString *&")
end)

-- 10 ---------------------------------------------------------------------
case("Nested class: definition Outer::Inner::f", function()
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
  T.run(dir .. "/n.h", "State state()", "Generate all missing definitions")
  T.has(dir .. "/n.cpp", "Outer::Inner::State Outer::Inner::state() const\n{\n}")
  T.has(dir .. "/n.cpp", "void Outer::Inner::reset()\n{\n}")
  T.lacks(dir .. "/n.cpp", "Outer::Outer()")
end)

-- 11 ---------------------------------------------------------------------
case("Operators", function()
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
  T.run(dir .. "/op.h", "operator==", "Generate all missing definitions")
  T.has(dir .. "/op.cpp", "bool Op::operator==(const Op &other) const\n{\n}")
  T.has(dir .. "/op.cpp", "bool Op::operator<(const Op &o) const\n{\n}")
  T.has(dir .. "/op.cpp", "int Op::operator()(int x)\n{\n}")
  T.has(dir .. "/op.cpp", "Op &Op::operator=(const Op &o)\n{\n}")
  T.has(dir .. "/op.cpp", "Op::operator bool() const\n{\n}")
  T.lacks(dir .. "/op.cpp", "explicit")
end)

-- 12 ---------------------------------------------------------------------
case("= default / = delete / pure virtual get no definition", function()
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
  T.run(dir .. "/v.h", "void go", "Generate all missing definitions")
  T.has(dir .. "/v.cpp", "V::~V()\n{\n}")
  T.has(dir .. "/v.cpp", "void V::go()\n{\n}")
  T.lacks(dir .. "/v.cpp", "V::run")
  T.lacks(dir .. "/v.cpp", "V::stop")
  T.lacks(dir .. "/v.cpp", "V::V(")
  no_title(dir .. "/v.h", "V() = default", "Generate definition for")
  no_title(dir .. "/v.h", "void run()", "Generate definition for")
end)

-- 13 ---------------------------------------------------------------------
case("Constructor with initializer list and default argument -> definition without default", function()
  local dir = T.project({
    ["k.h"] = { "class K : public QObject {", "    Q_OBJECT", "public:", "    explicit K(int a = 1, QObject *parent = nullptr);", "};" },
    ["k.cpp"] = { '#include "k.h"' },
  })
  T.run(dir .. "/k.h", "explicit K(", "Generate definition for K()")
  T.has(dir .. "/k.cpp", "K::K(int a, QObject *parent)\n{\n}")
end)

-- 14 ---------------------------------------------------------------------
case("Insertion position: after the definition of the previous declaration", function()
  local dir = T.project({
    ["o.h"] = { "class Ord {", "public:", "    void a();", "    void b();", "    void c();", "};" },
    ["o.cpp"] = {
      '#include "o.h"', "", "void Ord::c()", "{", "}", "", "void Ord::a()", "{", "}", "", "// End",
    },
  })
  T.run(dir .. "/o.h", "void b", "Generate definition for b()")
  T.has(dir .. "/o.cpp", "void Ord::a()\n{\n}\n\nvoid Ord::b()\n{\n}\n\n// End")
end)

-- 15 ---------------------------------------------------------------------
case("Nested namespace blocks in the .cpp", function()
  local dir = T.project({
    ["nn.h"] = { "namespace a {", "namespace b {", "class N {", "public:", "    void x();", "    void y();", "};", "}", "}" },
    ["nn.cpp"] = {
      '#include "nn.h"', "", "namespace a {", "namespace b {", "", "void N::x()", "{", "}", "", "} // namespace b", "} // namespace a",
    },
  })
  T.run(dir .. "/nn.h", "void y", "Generate definition for y()")
  T.has(dir .. "/nn.cpp", "void N::x()\n{\n}\n\nvoid N::y()\n{\n}\n\n} // namespace b")
  T.lacks(dir .. "/nn.cpp", "a::b::N::y")
  T.eq(count(dir .. "/nn.cpp", "namespace a {"), 1, "no second namespace block")
end)

-- 16 ---------------------------------------------------------------------
case("using namespace in .cpp", function()
  local dir = T.project({
    ["u.h"] = { "namespace lib {", "class U {", "public:", "    void x();", "};", "}" },
    ["u.cpp"] = { '#include "u.h"', "", "using namespace lib;", "", "void U::w() {}" },
  })
  T.run(dir .. "/u.h", "void x", "Generate definition for x()")
  T.has(dir .. "/u.cpp", "void U::x()\n{\n}")
  T.lacks(dir .. "/u.cpp", "namespace lib {")
end)

-- 17 ---------------------------------------------------------------------
case("Anonymous namespace in the .cpp: do not write into it", function()
  local dir = T.project({
    ["an.h"] = { "class An {", "public:", "    void x();", "};" },
    ["an.cpp"] = { '#include "an.h"', "", "namespace {", "int helper() { return 1; }", "}", "" },
  })
  T.run(dir .. "/an.h", "void x", "Generate definition for x()")
  T.has(dir .. "/an.cpp", "namespace {\nint helper() { return 1; }\n}\n")
  local txt = T.text(dir .. "/an.cpp")
  local ns_end = txt:find("}\n", txt:find("helper"), true)
  local def = txt:find("void An::x()", 1, true)
  assert(def and def > ns_end, "Definition is inside the anonymous namespace:\n" .. txt)
end)

-- 18 ---------------------------------------------------------------------
case("Class template: definition in the header, not in the .cpp", function()
  local dir = T.project({
    ["tp.h"] = { "template <typename T>", "class Box {", "public:", "    T get() const;", "private:", "    T mValue;", "};" },
    ["tp.cpp"] = { '#include "tp.h"' },
  })
  no_title(dir .. "/tp.h", "T get", "in tp.cpp")
  T.run(dir .. "/tp.h", "T get", "outside the class")
  T.has(dir .. "/tp.h", "template <typename T>\nT Box<T>::get() const\n{\n}")
  T.run(dir .. "/tp.h", "T mValue", "Getter and setter")
  T.lacks(dir .. "/tp.cpp", "Box")
  T.has(dir .. "/tp.h", "void setValue(const T &value);")
end)

-- 19 ---------------------------------------------------------------------
case("Two actions in a row (cache invalidation)", function()
  local dir = T.project({
    ["two.h"] = { "class Two {", "public:", "    void a();", "    void b();", "private:", "    int mX;", "};" },
    ["two.cpp"] = { '#include "two.h"' },
  })
  T.run(dir .. "/two.h", "void a", "Generate definition for a()")
  no_title(dir .. "/two.h", "void a", "Generate definition for a()")
  T.run(dir .. "/two.h", "int mX", "Getter and setter")
  -- Lines have shifted; b() must still be found correctly
  T.run(dir .. "/two.h", "void b", "Generate definition for b()")
  T.eq(count(dir .. "/two.cpp", "void Two::a()"), 1)
  T.eq(count(dir .. "/two.cpp", "void Two::b()"), 1)
  T.eq(count(dir .. "/two.cpp", "int Two::x() const"), 1)
  -- All missing: nothing left now
  no_title(dir .. "/two.h", "void a", "all missing definitions")
end)

-- 20 ---------------------------------------------------------------------
case("Visual range over several members including a comment line", function()
  local dir = T.project({
    ["r.h"] = {
      "class R {",
      "public:",
      "    R();",
      "private:",
      "    int mA;",
      "    // Separator",
      "    QString mB;",
      "    bool mC;",
      "};",
    },
    ["r.cpp"] = { '#include "r.h"' },
  })
  T.run(dir .. "/r.h", "int mA", "Getter and setter for 3 members", "bool mC")
  T.has(dir .. "/r.h", "    R();\n    int a() const;\n    void setA(int a);\n    QString b() const;\n    void setB(const QString &b);\n    bool c() const;\n    void setC(bool c);\nprivate:")
end)

-- 21 ---------------------------------------------------------------------
case("#ifdef in the class body: do not insert anything between #ifdef/#endif", function()
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
  T.run(dir .. "/if.h", "int mV", "Getter and setter")
  local txt = T.text(dir .. "/if.h")
  local s, e = txt:find("#ifdef HAS_EXTRA.-#endif")
  local seg = txt:sub(s, e)
  assert(not seg:find("int v() const", 1, true), "Getter inserted inside #ifdef:\n" .. txt)
  T.has(dir .. "/if.h", "int v() const;")
end)

-- 22 ---------------------------------------------------------------------
case("Tabs as indentation are preserved", function()
  local dir = T.project({
    ["tab.h"] = { "class Tab {", "public:", "\tTab();", "private:", "\tint mV;", "};" },
    ["tab.cpp"] = { '#include "tab.h"' },
  })
  T.run(dir .. "/tab.h", "int mV", "Getter and setter")
  T.has(dir .. "/tab.h", "\tTab();\n\tint v() const;\n\tvoid setV(int v);")
end)

-- 23 ---------------------------------------------------------------------
case("Move an inline definition with a comment and nested braces", function()
  local dir = T.project({
    ["mv.h"] = {
      "class Mv {",
      "public:",
      "    int f(int a = 3) const { // comment }",
      "        if (a) { return 1; }",
      "        return \"}\"[0];",
      "    }",
      "    void g();",
      "};",
    },
    ["mv.cpp"] = { '#include "mv.h"' },
  })
  T.run(dir .. "/mv.h", "int f(", "Move definition")
  T.has(dir .. "/mv.h", "    int f(int a = 3) const;\n    void g();")
  T.has(dir .. "/mv.cpp", "int Mv::f(int a) const\n{")
  T.has(dir .. "/mv.cpp", "return \"}\"[0];")
end)

-- 24 ---------------------------------------------------------------------
case("Add a declaration from the .cpp to a class in a namespace (namespace block)", function()
  local dir = T.project({
    ["dn.h"] = { "namespace app {", "class Dn {", "public:", "    Dn();", "private:", "    int mX;", "};", "}" },
    ["dn.cpp"] = { '#include "dn.h"', "", "namespace app {", "", "void Dn::helper(const QString &s, int n)", "{", "}", "", "}" },
  })
  T.run(dir .. "/dn.cpp", "Dn::helper", "private declaration")
  T.has(dir .. "/dn.h", "private:\n    int mX;\n    void helper(const QString &s, int n);\n};")
end)

-- 25 ---------------------------------------------------------------------
case("Declaration for Outer::Inner from the .cpp", function()
  local dir = T.project({
    ["oi.h"] = { "class Outer {", "public:", "    struct Inner {", "        int x;", "    };", "};" },
    ["oi.cpp"] = { '#include "oi.h"', "", "int Outer::Inner::twice() const", "{", "    return x * 2;", "}" },
  })
  T.run(dir .. "/oi.cpp", "Outer::Inner::twice", "public declaration")
  T.has(dir .. "/oi.h", "    struct Inner {\n        int x;\n        int twice() const;\n    };")
end)

-- 26 ---------------------------------------------------------------------
case("Q_PROPERTY with MEMBER/CONSTANT generates nothing nonsensical", function()
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
  T.run(dir .. "/qp.h", "QList<int> values", "Generate missing members for Q_PROPERTY", "int id READ")
  T.has(dir .. "/qp.h", "QList<int> values() const;")
  T.has(dir .. "/qp.h", "int id() const;")
  T.lacks(dir .. "/qp.h", "setValues")
  T.lacks(dir .. "/qp.h", "setId")
  T.lacks(dir .. "/qp.h", "idChanged")
  T.has(dir .. "/qp.h", "void valuesChanged();")
  T.has(dir .. "/qp.cpp", "QList<int> Qp::values() const\n{\n    return mValues;\n}")
end)

-- 27 ---------------------------------------------------------------------
case("CRLF files: no mixed line endings / no \\r in the name", function()
  local dir = T.project({
    ["cr.h"] = { "class Cr {\r", "public:\r", "    void x();\r", "private:\r", "    int mV;\r", "};\r" },
    ["cr.cpp"] = { '#include "cr.h"\r' },
  })
  T.run(dir .. "/cr.h", "int mV", "Getter and setter")
  T.lacks(dir .. "/cr.h", "\r(")
  T.lacks(dir .. "/cr.cpp", "\r(")
  T.has(dir .. "/cr.cpp", "int Cr::v() const")
end)

-- 28 ---------------------------------------------------------------------
case("Return with nested enum + default argument with template/comma", function()
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
  T.run(dir .. "/ra.h", "Mode pick", "Generate all missing definitions")
  T.has(dir .. "/ra.cpp", "Ra::Mode Ra::pick(const QMap<QString, int> &m, int n) const\n{\n}")
  T.has(dir .. "/ra.cpp", "QList<Ra::Mode> Ra::modes()\n{\n}")
end)

-- 29 ---------------------------------------------------------------------
case("Array member: no nonsensical getters/setters with array type", function()
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
case("Signal with changed signal already exists -> not duplicated", function()
  local dir = T.project({
    ["ex.h"] = {
      "class Ex : public QObject {", "    Q_OBJECT", "public:", "    int value() const;", "Q_SIGNALS:",
      "    void valueChanged();", "private:", "    int mValue;", "};",
    },
    ["ex.cpp"] = { '#include "ex.h"', "", "int Ex::value() const { return mValue; }" },
  })
  T.run(dir .. "/ex.h", "int mValue", "Getter, setter and changed signal")
  T.eq(count(dir .. "/ex.h", "valueChanged()"), 1)
  T.eq(count(dir .. "/ex.h", "int value() const"), 1)
  T.has(dir .. "/ex.h", "void setValue(int value);")
  T.eq(count(dir .. "/ex.cpp", "Ex::value()"), 1)
end)

-- 31 ---------------------------------------------------------------------
case("struct: default access public, brace initializer on a member", function()
  local dir = T.project({
    ["sr.h"] = { "struct Sr", "{", "    Sr();", "    QString mName{QStringLiteral(\"x\")};", "    int mN = 4;", "};" },
    ["sr.cpp"] = { '#include "sr.h"' },
  })
  T.run(dir .. "/sr.h", "QString mName", "Getter and setter")
  T.has(dir .. "/sr.h", "QString name() const;")
  T.has(dir .. "/sr.h", "void setName(const QString &name);")
  T.has(dir .. "/sr.cpp", "QString Sr::name() const\n{\n    return mName;\n}")
  T.lacks(dir .. "/sr.h", "private:\n    QString name() const")
end)

-- 32 ---------------------------------------------------------------------
case("Specifiers: noexcept, [[nodiscard]], override final, trailing return, ref-qualifier", function()
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
  T.run(dir .. "/sp.h", "int a()", "Generate all missing definitions")
  T.has(dir .. "/sp.cpp", "int Sp::a() const noexcept\n{\n}")
  T.has(dir .. "/sp.cpp", "void Sp::b()\n{\n}")
  T.has(dir .. "/sp.cpp", "auto Sp::c() const -> QString\n{\n}")
  T.has(dir .. "/sp.cpp", "QString Sp::d() const &\n{\n}")
  T.has(dir .. "/sp.cpp", "int Sp::e(int x)\n{\n}")
  T.lacks(dir .. "/sp.cpp", "override")
  T.lacks(dir .. "/sp.cpp", "Q_INVOKABLE")
end)

-- 33 ---------------------------------------------------------------------
case("Signals at the end of the class behind #endif: do not insert into #ifdef", function()
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
  T.run(dir .. "/se.h", "int mV", "Getter, setter and changed signal")
  local txt = T.text(dir .. "/se.h")
  local seg = txt:match("#ifdef DEBUG.-#endif")
  assert(not seg:find("vChanged", 1, true), "Signal inserted inside #ifdef:\n" .. txt)
  T.has(dir .. "/se.h", "void vChanged();")
end)

-- 34 ---------------------------------------------------------------------
case("Move an inline definition in a class inside a namespace", function()
  local dir = T.project({
    ["mn.h"] = { "namespace ns {", "class Mn {", "public:", "    int v() const { return 1; }", "};", "} // namespace ns" },
    ["mn.cpp"] = { '#include "mn.h"', "", "namespace ns {", "", "} // namespace ns" },
  })
  T.run(dir .. "/mn.h", "int v()", "Move definition")
  T.has(dir .. "/mn.h", "    int v() const;")
  T.has(dir .. "/mn.cpp", "namespace ns {\n\nint Mn::v() const\n{\n    return 1;\n}\n\n} // namespace ns")
end)

-- 35 ---------------------------------------------------------------------
case("Pointer to const is not a const member", function()
  local dir = T.project({
    ["pc.h"] = { "class Pc {", "public:", "    Pc();", "private:", "    const QString *mText;", "};" },
    ["pc.cpp"] = { '#include "pc.h"' },
  })
  T.run(dir .. "/pc.h", "mText", "Getter and setter")
  T.has(dir .. "/pc.h", "    const QString *text() const;\n    void setText(const QString *text);")
end)
