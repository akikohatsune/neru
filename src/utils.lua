local http = require('coro-http')
local has_fs, fs = pcall(require, 'fs')

local M = {}

function M.trim(value)
  if value == nil then
    return ''
  end
  return tostring(value):match('^%s*(.-)%s*$')
end

function M.starts_with(text, prefix)
  return text:sub(1, #prefix) == prefix
end

function M.to_bool(raw, default_value)
  if raw == nil or raw == '' then
    return default_value
  end
  local value = M.trim(raw):lower()
  if value == '1' or value == 'true' or value == 'yes' or value == 'on' then
    return true
  end
  if value == '0' or value == 'false' or value == 'no' or value == 'off' then
    return false
  end
  error('Invalid boolean value: ' .. tostring(raw))
end

function M.to_int(raw, name, default_value, minimum)
  local value = tonumber(raw)
  if value == nil then
    value = default_value
  end
  value = math.floor(value)
  if minimum ~= nil and value < minimum then
    return minimum
  end
  return value
end

function M.to_float(raw, name, default_value)
  local value = tonumber(raw)
  if value == nil then
    return default_value
  end
  return value
end

function M.dirname(path)
  local normalized = path:gsub('\\', '/')
  local dir = normalized:match('^(.*)/[^/]+$')
  if dir == nil or dir == '' then
    return '.'
  end
  return dir
end

function M.ensure_parent_dir(file_path)
  local dir = M.dirname(file_path)
  if dir ~= '.' and not M.path_exists(dir) then
    M.mkdirp(dir)
  end
end

function M.read_file(path)
  if not M.path_exists(path) then
    return nil
  end
  if has_fs and fs and fs.readFileSync then
    return fs.readFileSync(path)
  end
  local file = io.open(path, 'rb')
  if not file then
    return nil
  end
  local content = file:read('*a')
  file:close()
  return content
end

function M.write_file(path, content)
  M.ensure_parent_dir(path)
  if has_fs and fs and fs.writeFileSync then
    fs.writeFileSync(path, content)
    return
  end
  local file = assert(io.open(path, 'wb'))
  file:write(content)
  file:close()
end

function M.append_file(path, content)
  M.ensure_parent_dir(path)
  if has_fs and fs and fs.appendFileSync then
    fs.appendFileSync(path, content)
    return
  end
  local file = assert(io.open(path, 'ab'))
  file:write(content)
  file:close()
end

function M.path_exists(path)
  if has_fs and fs and fs.existsSync then
    return fs.existsSync(path)
  end
  local file = io.open(path, 'rb')
  if file then
    file:close()
    return true
  end
  local sep = package.config:sub(1, 1)
  if sep == '\\' then
    local code = os.execute('if exist "' .. path .. '" (exit /b 0) else (exit /b 1)')
    return code == true or code == 0
  end
  local code = os.execute('[ -e "' .. path .. '" ]')
  return code == true or code == 0
end

function M.mkdirp(path)
  if has_fs and fs and fs.mkdirpSync then
    fs.mkdirpSync(path)
    return
  end
  local sep = package.config:sub(1, 1)
  if sep == '\\' then
    os.execute('mkdir "' .. path .. '" >NUL 2>NUL')
  else
    os.execute('mkdir -p "' .. path .. '"')
  end
end

function M.now_unix()
  return os.time()
end

function M.now_iso_utc()
  return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

function M.split_lines(text)
  local lines = {}
  for line in tostring(text):gmatch('[^\r\n]+') do
    table.insert(lines, line)
  end
  return lines
end

function M.chunk_text(text, max_len)
  local chunks = {}
  local idx = 1
  local length = #text
  while idx <= length do
    table.insert(chunks, text:sub(idx, idx + max_len - 1))
    idx = idx + max_len
  end
  if #chunks == 0 then
    table.insert(chunks, '(no content)')
  end
  return chunks
end

function M.sanitize_mentions(text)
  local zero_width = string.char(226, 128, 139)
  local out = tostring(text)
  out = out:gsub('@everyone', '@' .. zero_width .. 'everyone')
  out = out:gsub('@here', '@' .. zero_width .. 'here')
  return out
end

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function M.base64_encode(data)
  return ((data:gsub('.', function(char)
    local byte = char:byte()
    local bits = ''
    for bit = 8, 1, -1 do
      bits = bits .. ((byte % 2 ^ bit - byte % 2 ^ (bit - 1) > 0) and '1' or '0')
    end
    return bits
  end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(bits)
    if #bits < 6 then
      return ''
    end
    local value = 0
    for i = 1, 6 do
      if bits:sub(i, i) == '1' then
        value = value + 2 ^ (6 - i)
      end
    end
    return b64chars:sub(value + 1, value + 1)
  end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

function M.http_get_bytes(url)
  local response, body = http.request('GET', url)
  local status = tonumber(response and response.code or 0) or 0
  local payload = body
  if type(payload) == 'table' then
    payload = table.concat(payload)
  end
  if status < 200 or status >= 300 then
    return nil, 'HTTP ' .. tostring(status)
  end
  return payload, nil
end

function M.extract_prefixed_command(content, prefix)
  local stripped = M.trim(content)
  if not M.starts_with(stripped, prefix) then
    return nil, nil
  end
  local rest = stripped:sub(#prefix + 1)
  local name, args = rest:match('^(%S+)%s*(.*)$')
  if name == nil then
    return nil, nil
  end
  return name:lower(), args or ''
end

function M.parse_user_id(value)
  local text = M.trim(value)
  local mention = text:match('^<@!?(%d+)>$')
  if mention then
    return tonumber(mention)
  end
  local raw = text:match('^(%d+)$')
  if raw then
    return tonumber(raw)
  end
  return nil
end

return M
