local T = _G.T

T.case("Q_PROPERTY + getter/setter/signal by pattern (bool mFoo)", function()
  local dir = T.project({
    ["a.h"] = { "class A : public QObject {", "    Q_OBJECT", "public:", "    A();", "private:", "    bool mFoo;", "};" },
    ["a.cpp"] = { '#include "a.h"', "", "A::A()", "{", "}" },
  })
  T.run(dir .. "/a.h", "bool mFoo", "Q_PROPERTY and missing members")
  T.has(dir .. "/a.h", "    Q_PROPERTY(bool foo READ foo WRITE setFoo NOTIFY fooChanged FINAL)")
  T.has(dir .. "/a.h", "    bool foo() const;\n    void setFoo(bool foo);\nprivate:")
  T.has(dir .. "/a.h", "signals:\n    void fooChanged();\n};")
  T.has(dir .. "/a.cpp", "bool A::foo() const\n{\n    return mFoo;\n}")
  T.has(dir .. "/a.cpp", "void A::setFoo(bool foo)\n{\n    if (mFoo == foo)\n        return;\n    mFoo = foo;\n    emit fooChanged();\n}")
end)

T.case("Configurable patterns (is-getter, Q_EMIT, Q_SIGNALS)", function()
  T.setup({
    naming = { bool_getter = "is{Name}", setter_param = "new{Name}" },
    signal = { emit = "Q_EMIT", keyword = "Q_SIGNALS" },
  })
  local dir = T.project({
    ["a.h"] = { "class A : public QObject {", "    Q_OBJECT", "public:", "    A();", "private:", "    bool m_valid;", "};" },
    ["a.cpp"] = { '#include "a.h"' },
  })
  T.run(dir .. "/a.h", "m_valid", "Getter, setter and changed signal")
  T.has(dir .. "/a.h", "bool isValid() const;")
  T.has(dir .. "/a.h", "void setValid(bool newValid);")
  T.has(dir .. "/a.h", "Q_SIGNALS:\n    void validChanged();")
  T.has(dir .. "/a.cpp", "Q_EMIT validChanged();")
end)

T.case("Const reference for classes, value for enums/pointers, qFuzzyCompare", function()
  local dir = T.project({
    ["a.h"] = {
      "class A {", "public:", "    enum Mode { X, Y };", "private:",
      "    QString mName;", "    Mode mMode;", "    QObject *mObj;", "    double mRatio;", "};",
    },
    ["a.cpp"] = { '#include "a.h"' },
  })
  T.run(dir .. "/a.h", "QString mName", "Getter and setter", "double mRatio")
  T.has(dir .. "/a.h", "void setName(const QString &name);")
  T.has(dir .. "/a.h", "void setMode(Mode mode);")
  T.has(dir .. "/a.h", "void setObj(QObject *obj);")
  T.has(dir .. "/a.cpp", "A::Mode A::mode() const")
end)

T.case("Definition from header declaration, default arguments/specifiers removed", function()
  local dir = T.project({
    ["w.h"] = {
      "namespace ui {", "class W {", "public:",
      "    Q_INVOKABLE virtual int f(int a, const QString &s = QString()) const override;",
      "    static W *make();", "};", "}",
    },
    ["w.cpp"] = { '#include "w.h"', "", "namespace ui {", "", "} // namespace ui" },
  })
  T.run(dir .. "/w.h", "int f(", "Generate all missing definitions")
  T.has(dir .. "/w.cpp", "int W::f(int a, const QString &s) const\n{\n}")
  T.has(dir .. "/w.cpp", "W *W::make()\n{\n}")
  T.has(dir .. "/w.cpp", "\n} // namespace ui")
end)

T.case("Create missing namespaces in the .cpp", function()
  local dir = T.project({
    ["n.h"] = { "namespace a::b {", "class N {", "public:", "    void x();", "};", "}" },
    ["n.cpp"] = { '#include "n.h"' },
  })
  T.run(dir .. "/n.h", "void x", "Generate definition for x()")
  T.has(dir .. "/n.cpp", '#include "n.h"\n\nnamespace a::b {\n\nvoid N::x()\n{\n}\n\n} // namespace a::b')
end)

T.case("Create a new .cpp including #include", function()
  local dir = T.project({
    ["z.h"] = { "class Z {", "public:", "    void x();", "};" },
  })
  T.run(dir .. "/z.h", "void x", "Generate definition for x()")
  T.has(dir .. "/z.cpp", '#include "z.h"\n\nvoid Z::x()\n{\n}')
end)

T.case("Source file via compile_commands.json", function()
  local dir = T.project({
    ["include/m/q.h"] = { "class Q {", "public:", "    void x();", "};" },
    ["src/m/q.cpp"] = { '#include "m/q.h"' },
    [".git/HEAD"] = { "" },
  })
  vim.fn.mkdir(dir .. "/build", "p")
  vim.fn.writefile({ vim.json.encode({ { directory = dir .. "/build", file = "../src/m/q.cpp", command = "c++" } }) },
    dir .. "/build/compile_commands.json")
  T.run(dir .. "/include/m/q.h", "void x", "in q.cpp")
  T.has(dir .. "/src/m/q.cpp", "void Q::x()")
end)

T.case("Move an inline definition to the .cpp", function()
  local dir = T.project({
    ["v.h"] = { "class V {", "public:", "    V(int a) : mA(a), mB{2} { init(); }", "    inline int get() const", "    {", "        return mA;", "    }", "};" },
    ["v.cpp"] = { '#include "v.h"' },
  })
  T.run(dir .. "/v.h", "inline int get", "Move definition")
  T.has(dir .. "/v.h", "    int get() const;")
  T.lacks(dir .. "/v.h", "return mA")
  T.has(dir .. "/v.cpp", "int V::get() const\n{\n    return mA;\n}")
  T.run(dir .. "/v.h", "V(int a)", "Move definition")
  T.has(dir .. "/v.h", "    V(int a);")
  T.has(dir .. "/v.cpp", "V::V(int a)\n    : mA(a), mB{2}\n{\n    init();\n}")
end)

T.case("Add a declaration from a .cpp definition to the header", function()
  local dir = T.project({
    ["d.h"] = { "class D {", "public:", "    D();", "};" },
    ["d.cpp"] = { '#include "d.h"', "", "int D::extra(int x) const", "{", "    return x;", "}" },
  })
  T.run(dir .. "/d.cpp", "D::extra", "public declaration")
  T.has(dir .. "/d.h", "    D();\n    int extra(int x) const;")
end)

T.case("Already defined functions are not offered", function()
  local dir = T.project({
    ["e.h"] = { "class E {", "public:", "    void a();", "    void b(int);", "};" },
    ["e.cpp"] = { '#include "e.h"', "void E::a() {}" },
  })
  local titles = vim.tbl_map(function(a)
    return a.title
  end, T.actions(dir .. "/e.h", "void a"))
  for _, t in ipairs(titles) do
    assert(not t:find("Generate definition for a()", 1, true), "a() is already defined")
  end
end)

T.case("Generate missing members from Q_PROPERTY", function()
  local dir = T.project({
    ["p.h"] = {
      "class P : public QObject {", "    Q_OBJECT",
      "    Q_PROPERTY(QString title READ title WRITE setTitle NOTIFY titleChanged)",
      "public:", "    P();", "};",
    },
    ["p.cpp"] = { '#include "p.h"' },
  })
  T.run(dir .. "/p.h", "Q_PROPERTY", "Generate missing members for Q_PROPERTY")
  T.has(dir .. "/p.h", "QString title() const;")
  T.has(dir .. "/p.h", "void setTitle(const QString &title);")
  T.has(dir .. "/p.h", "void titleChanged();")
  T.has(dir .. "/p.h", "private:\n    QString mTitle;")
  T.has(dir .. "/p.cpp", "return mTitle;")
end)

T.case("cmake-tools.nvim: build directory (plenary Path) → compile_commands.json", function()
  local dir = T.project({
    ["a/c.h"] = { "class C {", "public:", "    void x();", "};" },
    ["b/c.cpp"] = { '#include "c.h"' },
  })
  local bdir = vim.fn.tempname() -- outside the project, findable only via cmake-tools
  vim.fn.mkdir(bdir, "p")
  vim.fn.writefile({ vim.json.encode({ { directory = bdir, file = dir .. "/b/c.cpp", command = "c++" } }) },
    bdir .. "/compile_commands.json")
  package.loaded["cmake-tools"] = {
    is_cmake_project = function()
      return true
    end,
    get_build_directory = function()
      return { filename = bdir } -- like plenary.Path
    end,
  }
  local ok, err = pcall(function()
    T.run(dir .. "/a/c.h", "void x", "in c.cpp")
    T.has(dir .. "/b/c.cpp", "void C::x()")
  end)
  package.loaded["cmake-tools"] = nil
  assert(ok, err)
end)
