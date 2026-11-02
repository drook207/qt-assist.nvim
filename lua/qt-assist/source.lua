-- Header ↔ source file mapping.
-- Order: same directory → clangd (switchSourceHeader) →
-- compile_commands.json (cmake-tools / qmake-tools / search) → search paths.
local config = require("qt-assist.config")

local M = {}

local uv = vim.uv or vim.loop

local function exists(path)
  return path and uv.fs_stat(path) ~= nil
end

local function stem(path)
  return vim.fn.fnamemodify(path, ":t:r")
end

local function ext(path)
  return vim.fn.fnamemodify(path, ":e")
end

function M.is_header(path)
  local e = ext(path)
  for _, h in ipairs(config.options.source.header_extensions) do
    if e == h then
      return true
    end
  end
  return false
end

function M.is_source(path)
  local e = ext(path)
  for _, h in ipairs(config.options.source.extensions) do
    if e == h then
      return true
    end
  end
  return false
end

local function normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

-- ---------------------------------------------------------------------------
-- compile_commands.json
-- ---------------------------------------------------------------------------

local cc_cache = {} -- path → { mtime, files }

--- Build directory from cmake-tools.nvim
local function cmake_tools_dir()
  local ok, cmake = pcall(require, "cmake-tools")
  if not ok or type(cmake.get_build_directory) ~= "function" then
    return nil
  end
  local ok2, is_cmake = pcall(function()
    return cmake.is_cmake_project()
  end)
  if ok2 and is_cmake == false then
    return nil
  end
  local ok3, dir = pcall(cmake.get_build_directory)
  if not ok3 or not dir then
    return nil
  end
  if type(dir) == "table" then
    dir = dir.filename or (dir.tostring and dir:tostring()) or tostring(dir)
  end
  return type(dir) == "string" and dir or nil
end

--- Build directory from qmake-tools.nvim
local function qmake_tools_dir()
  local ok, qt = pcall(require, "qmake-tools")
  if not ok then
    return nil
  end
  if type(qt.is_qmake_project) == "function" then
    local ok2, is = pcall(qt.is_qmake_project)
    if ok2 and not is then
      return nil
    end
  end
  local ok3, project = pcall(require, "qmake-tools.project")
  if not ok3 then
    return nil
  end
  local ok4, dir = pcall(function()
    local p = project.get(true)
    return p and project.build_dir(p)
  end)
  return ok4 and dir or nil
end

--- compile_commands directory from the clangd command line
local function clangd_dir(bufnr)
  local get = vim.lsp.get_clients or vim.lsp.get_active_clients
  for _, c in ipairs(get({ bufnr = bufnr, name = "clangd" })) do
    local cmd = c.config and c.config.cmd
    if type(cmd) == "table" then
      for i, a in ipairs(cmd) do
        local d = a:match("^%-%-compile%-commands%-dir=(.+)$")
        if d then
          return d
        elseif a == "--compile-commands-dir" and cmd[i + 1] then
          return cmd[i + 1]
        end
      end
    end
    if c.config and c.config.root_dir then
      return c.config.root_dir
    end
  end
end

--- All candidates for compile_commands.json for a file
function M.compile_commands_files(bufnr, file)
  local o = config.options.source
  local res, seen = {}, {}
  local function add(p)
    if p and p ~= "" then
      if not p:match("compile_commands%.json$") then
        p = vim.fs.joinpath(p, "compile_commands.json")
      end
      p = normalize(p)
      if not seen[p] and exists(p) then
        seen[p] = true
        res[#res + 1] = p
      end
    end
  end
  if type(o.compile_commands) == "function" then
    add(o.compile_commands(bufnr))
  elseif type(o.compile_commands) == "string" then
    add(o.compile_commands)
  end
  add(cmake_tools_dir())
  add(qmake_tools_dir())
  add(clangd_dir(bufnr))
  -- Search upwards, also in build*/
  for d in vim.fs.parents(file) do
    add(d)
    local handle = uv.fs_scandir(d)
    if handle then
      while true do
        local name, typ = uv.fs_scandir_next(handle)
        if not name then
          break
        end
        if (typ == "directory" or typ == "link") and name:lower():match("^build") or name == "out" then
          add(vim.fs.joinpath(d, name))
        end
      end
    end
    if exists(vim.fs.joinpath(d, ".git")) then
      break
    end
  end
  return res
end

--- File list of a compile_commands.json (cached by mtime)
function M.compile_commands_entries(path)
  local st = uv.fs_stat(path)
  if not st then
    return {}
  end
  local c = cc_cache[path]
  if c and c.mtime == st.mtime.sec and c.size == st.size then
    return c.files
  end
  local fd = io.open(path, "r")
  if not fd then
    return {}
  end
  local data = fd:read("*a")
  fd:close()
  local ok, list = pcall(vim.json.decode, data)
  local files = {}
  if ok and type(list) == "table" then
    for _, e in ipairs(list) do
      if type(e) == "table" and e.file then
        local f = e.file
        if not f:match("^/") and not f:match("^%a:[/\\]") and e.directory then
          f = vim.fs.joinpath(e.directory, f)
        end
        files[#files + 1] = vim.fs.normalize(f)
      end
    end
  end
  cc_cache[path] = { mtime = st.mtime.sec, size = st.size, files = files }
  return files
end

local function common_prefix_len(a, b)
  local n = 0
  local pa = vim.split(a, "/", { plain = true })
  local pb = vim.split(b, "/", { plain = true })
  for i = 1, math.min(#pa, #pb) do
    if pa[i] ~= pb[i] then
      break
    end
    n = n + 1
  end
  return n
end

--- Best candidate by path proximity
local function closest(file, candidates)
  local best, best_n
  for _, c in ipairs(candidates) do
    local n = common_prefix_len(file, c)
    if not best or n > best_n then
      best, best_n = c, n
    end
  end
  return best
end

-- ---------------------------------------------------------------------------
-- Find the counterpart
-- ---------------------------------------------------------------------------

local function same_dir_candidate(file, exts)
  local base = vim.fn.fnamemodify(file, ":r")
  for _, e in ipairs(exts) do
    if exists(base .. "." .. e) then
      return normalize(base .. "." .. e)
    end
  end
end

local function clangd_switch(bufnr)
  if not config.options.source.use_clangd then
    return nil
  end
  local get = vim.lsp.get_clients or vim.lsp.get_active_clients
  for _, c in ipairs(get({ bufnr = bufnr, name = "clangd" })) do
    local params = { uri = vim.uri_from_bufnr(bufnr) }
    local ok, resp = pcall(function()
      if vim.fn.has("nvim-0.11") == 1 then
        return c:request_sync("textDocument/switchSourceHeader", params, 1000, bufnr)
      end
      return c.request_sync("textDocument/switchSourceHeader", params, 1000, bufnr)
    end)
    if ok and resp and resp.result and type(resp.result) == "string" then
      local f = vim.uri_to_fname(resp.result)
      if exists(f) then
        return normalize(f)
      end
    end
  end
end

--- Find the source file for a header
---@return string|nil path, string|nil how
function M.find_source(bufnr)
  local file = normalize(vim.api.nvim_buf_get_name(bufnr))
  local o = config.options.source
  local s = same_dir_candidate(file, o.extensions)
  if s then
    return s, "same directory"
  end
  local sw = clangd_switch(bufnr)
  if sw and M.is_source(sw) then
    return sw, "clangd"
  end
  if o.use_compile_commands then
    local name = stem(file)
    local cands = {}
    for _, cc in ipairs(M.compile_commands_files(bufnr, file)) do
      for _, f in ipairs(M.compile_commands_entries(cc)) do
        if stem(f) == name and M.is_source(f) and exists(f) then
          cands[#cands + 1] = f
        end
      end
      if #cands > 0 then
        return closest(file, cands), "compile_commands.json"
      end
    end
  end
  local dir = vim.fs.dirname(file)
  local name = stem(file)
  for _, d in ipairs(o.search_dirs) do
    for _, e in ipairs(o.extensions) do
      local p = vim.fs.joinpath(dir, d, name .. "." .. e)
      if exists(p) then
        return normalize(p), "search path"
      end
    end
  end
  -- include/foo/bar.h → src/foo/bar.cpp
  local inc = file:match("^(.*)/include/")
  if inc then
    local rel = file:sub(#inc + 10)
    for _, e in ipairs(o.extensions) do
      local p = vim.fs.joinpath(inc, "src", vim.fn.fnamemodify(rel, ":r") .. "." .. e)
      if exists(p) then
        return normalize(p), "include→src"
      end
    end
  end
end

--- Find the header for a source file (for "add declaration")
---@param parsed table|nil Parse result of the source (for the #include list)
function M.find_header(bufnr, parsed)
  local file = normalize(vim.api.nvim_buf_get_name(bufnr))
  local o = config.options.source
  local s = same_dir_candidate(file, o.header_extensions)
  if s then
    return s
  end
  local sw = clangd_switch(bufnr)
  if sw and M.is_header(sw) then
    return sw
  end
  local name = stem(file)
  local dir = vim.fs.dirname(file)
  if parsed then
    for _, inc in ipairs(parsed.includes) do
      if stem(inc.path) == name then
        for _, d in ipairs({ ".", "..", "../include", "include" }) do
          local p = vim.fs.joinpath(dir, d, inc.path)
          if exists(p) then
            return normalize(p)
          end
        end
        -- Include paths from compile_commands are expensive; search the project
        local found = vim.fs.find(vim.fs.basename(inc.path), {
          path = vim.fs.root(file, { ".git", "CMakeLists.txt" }) or dir,
          type = "file",
          limit = 5,
        })
        if #found > 0 then
          return normalize(closest(file, found))
        end
      end
    end
  end
  for _, d in ipairs({ ".", "../include", "include", ".." }) do
    for _, e in ipairs(o.header_extensions) do
      local p = vim.fs.joinpath(dir, d, name .. "." .. e)
      if exists(p) then
        return normalize(p)
      end
    end
  end
end

--- Proposal for a new source file to create
function M.default_source_path(header)
  return vim.fn.fnamemodify(header, ":r") .. "." .. config.options.source.extensions[1]
end

--- Include line for the header from the source's point of view
function M.include_for(header, source)
  local hdir = vim.fs.dirname(header)
  local sdir = vim.fs.dirname(source)
  if hdir == sdir then
    return vim.fs.basename(header)
  end
  -- include/<x>/y.h → <x>/y.h
  local after = header:match("/include/(.+)$")
  if after then
    return after
  end
  return vim.fs.basename(header)
end

return M
