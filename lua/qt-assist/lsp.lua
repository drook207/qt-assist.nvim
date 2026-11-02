-- Small in-process language server that only provides code actions. This makes
-- the actions appear in vim.lsp.buf.code_action() (and in pickers like
-- telescope/fzf-lua/actions-preview) directly next to clangd's.
local config = require("qt-assist.config")

local M = {}

local COMMAND = "qt-assist.run"
local pending = {} -- id → action
local next_id = 0

local function store(action)
  next_id = next_id + 1
  pending[next_id] = action
  return next_id
end

local function code_actions(params)
  local buf = vim.uri_to_bufnr(params.textDocument.uri)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return {}
  end
  local r = params.range
  local l1, l2 = r.start.line, r["end"].line
  -- A range end in column 0 is no longer part of it (visual line selection)
  if l2 > l1 and r["end"].character == 0 then
    l2 = l2 - 1
  end
  pending = {}
  local res = {}
  for _, a in ipairs(require("qt-assist.actions").collect(buf, l1, l2)) do
    local id = store(a)
    res[#res + 1] = {
      title = a.title,
      kind = a.kind,
      command = { title = a.title, command = COMMAND, arguments = { id } },
    }
  end
  return res
end

local function execute(params)
  local id = params.arguments and params.arguments[1]
  local a = pending[id]
  if not a then
    vim.notify("qt-assist: action no longer valid – please invoke again", vim.log.levels.WARN)
    return
  end
  local ok, err = pcall(a.run)
  if not ok then
    vim.notify("qt-assist: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- cmd function for vim.lsp.start
local function server(dispatchers)
  local closing = false
  local srv = {}
  local msg_id = 0

  function srv.request(method, params, callback, notify_reply_callback)
    msg_id = msg_id + 1
    local id = msg_id
    local result, err
    if method == "initialize" then
      result = {
        capabilities = {
          codeActionProvider = { codeActionKinds = { "refactor.rewrite" } },
          executeCommandProvider = { commands = { COMMAND } },
        },
        serverInfo = { name = config.options.lsp.name, version = "1.0" },
      }
    elseif method == "textDocument/codeAction" then
      local ok, r = pcall(code_actions, params)
      result = ok and r or {}
      if not ok and vim.g.qt_assist_debug then
        vim.notify("qt-assist: " .. tostring(r), vim.log.levels.ERROR)
      end
    elseif method == "workspace/executeCommand" then
      if params.command == COMMAND then
        vim.schedule(function()
          execute(params)
        end)
      end
      result = vim.NIL
    elseif method == "shutdown" then
      result = vim.NIL
    else
      err = { code = -32601, message = "Method not found: " .. method }
    end
    vim.schedule(function()
      callback(err, result)
      if notify_reply_callback then
        notify_reply_callback(id)
      end
    end)
    return true, id
  end

  function srv.notify(method, _)
    if method == "exit" then
      closing = true
      dispatchers.on_exit(0, 15)
    end
    return true
  end

  function srv.is_closing()
    return closing
  end

  function srv.terminate()
    closing = true
  end

  return srv
end

--- Client-side command (preferred over workspace/executeCommand)
vim.lsp.commands[COMMAND] = function(command)
  execute({ arguments = command.arguments })
end

local function root_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return vim.fs.root and vim.fs.root(name, { ".git", "compile_commands.json", "CMakeLists.txt" })
    or vim.fs.dirname(name)
end

--- Attach the server to a buffer
function M.attach(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == "" then
    return
  end
  vim.lsp.start({
    name = config.options.lsp.name,
    cmd = server,
    root_dir = root_dir(buf),
  }, { bufnr = buf, reuse_client = function(client, conf)
    return client.name == conf.name
  end })
end

function M.setup()
  local group = vim.api.nvim_create_augroup("qt-assist-lsp", { clear = true })
  if not config.options.lsp.enabled then
    return
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = config.options.lsp.filetypes,
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
  -- already open buffers
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(config.options.lsp.filetypes, vim.bo[buf].filetype) then
      M.attach(buf)
    end
  end
end

return M
