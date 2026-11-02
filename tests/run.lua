-- Headless tests:  nvim --headless -u NONE -l tests/run.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.o.hidden = true
vim.o.swapfile = false

local T = {}
local cases = {}
local failures = 0

function T.case(name, fn)
  cases[#cases + 1] = { name = name, fn = fn }
end

--- Create a project in a temporary directory
function T.project(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for path, content in pairs(files) do
    local full = dir .. "/" .. path
    vim.fn.mkdir(vim.fs.dirname(full), "p")
    local lines = type(content) == "table" and content or vim.split(content, "\n", { plain = true })
    vim.fn.writefile(lines, full)
  end
  return dir
end

function T.open(path)
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  vim.api.nvim_set_current_buf(b)
  return b
end

function T.lines(path)
  local b = vim.fn.bufnr(path)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  return vim.fn.readfile(path)
end

function T.text(path)
  return table.concat(T.lines(path), "\n")
end

--- Actions on the first line containing `pat`
function T.actions(path, pat, pat2)
  local b = T.open(path)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local function find(p)
    for i, l in ipairs(lines) do
      if l:find(p, 1, true) then
        return i - 1
      end
    end
    error("line not found: " .. p)
  end
  local l1 = find(pat)
  local l2 = pat2 and find(pat2) or l1
  return require("qt-assist").actions(b, l1, l2)
end

--- Run the action whose title contains `title`
function T.run(path, pat, title, pat2)
  local list = T.actions(path, pat, pat2)
  for _, a in ipairs(list) do
    if a.title:find(title, 1, true) then
      a.run()
      return a
    end
  end
  local titles = vim.tbl_map(function(a)
    return a.title
  end, list)
  error("action not found: " .. title .. "\navailable: " .. vim.inspect(titles))
end

function T.has(path, needle)
  local txt = T.text(path)
  if not txt:find(needle, 1, true) then
    error(("expected in %s:\n%s\n---- Content ----\n%s"):format(vim.fs.basename(path), needle, txt), 2)
  end
end

function T.lacks(path, needle)
  local txt = T.text(path)
  if txt:find(needle, 1, true) then
    error(("not expected in %s:\n%s\n---- Content ----\n%s"):format(vim.fs.basename(path), needle, txt), 2)
  end
end

function T.eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error((msg or "not equal") .. "\nexpected: " .. vim.inspect(b) .. "\nactual: " .. vim.inspect(a), 2)
  end
end

function T.setup(opts)
  opts = vim.tbl_deep_extend("force", { lsp = { enabled = false }, source = { create_missing = true, use_clangd = false } }, opts or {})
  require("qt-assist").setup(opts)
  require("qt-assist.actions").clear_cache()
end

_G.T = T

for _, f in ipairs(vim.fn.globpath(root .. "/tests", "test_*.lua", false, true)) do
  dofile(f)
end

local only = os.getenv("TEST_FILTER")
for _, c in ipairs(cases) do
  if not only or c.name:find(only, 1, true) then
    -- fresh buffers per test
    vim.cmd("silent! %bwipeout!")
    T.setup()
    local ok, err = xpcall(c.fn, debug.traceback)
    if ok then
      print("ok    " .. c.name)
    else
      failures = failures + 1
      print("FAIL  " .. c.name .. "\n" .. err)
    end
  end
end
print(("%d tests, %d failures"):format(#cases, failures))
os.exit(failures == 0 and 0 or 1)
