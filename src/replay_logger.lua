local json = require('json')
local utils = require('src.utils')

local ReplayLogger = {}
ReplayLogger.__index = ReplayLogger

function ReplayLogger.new(log_path)
  local self = setmetatable({}, ReplayLogger)
  self.log_path = log_path
  self.next_id = 1
  return self
end

function ReplayLogger:initialize()
  local raw = utils.read_file(self.log_path)
  if not raw then
    utils.write_file(self.log_path, '')
    self.next_id = 1
    return
  end
  local max_id = 0
  for _, line in ipairs(utils.split_lines(raw)) do
    local ok, item = pcall(json.decode, line)
    if ok and type(item) == 'table' and item.type == 'chat' and type(item.id) == 'number' then
      if item.id > max_id then
        max_id = item.id
      end
    end
  end
  self.next_id = max_id + 1
end

function ReplayLogger:log_chat(record)
  record.id = self.next_id
  record.type = 'chat'
  record.ts_utc = utils.now_iso_utc()
  record.prompt = tostring(record.prompt or ''):sub(1, 600)
  local line = json.encode(record)
  utils.append_file(self.log_path, line .. '\n')
  self.next_id = self.next_id + 1
end

function ReplayLogger:log_error(record)
  local payload = {
    type = 'error',
    ts_utc = utils.now_iso_utc(),
    guild_id = record.guild_id,
    guild_name = record.guild_name,
    channel_id = record.channel_id,
    channel_name = record.channel_name,
    user_id = record.user_id,
    user_name = record.user_name,
    user_display = record.user_display,
    trigger = record.trigger,
    prompt = tostring(record.prompt or ''):sub(1, 600),
    error = tostring(record.error or ''):sub(1, 2000),
  }
  local line = json.encode(payload)
  utils.append_file(self.log_path, line .. '\n')
end

function ReplayLogger:_iter_records(guild_id)
  local raw = utils.read_file(self.log_path)
  local records = {}
  if not raw then
    return records
  end
  local fallback_id = 0
  for _, line in ipairs(utils.split_lines(raw)) do
    local ok, item = pcall(json.decode, line)
    if ok and type(item) == 'table' and item.type == 'chat' then
      local record_id = tonumber(item.id)
      if not record_id or record_id <= 0 then
        fallback_id = fallback_id + 1
        record_id = fallback_id
      elseif record_id > fallback_id then
        fallback_id = record_id
      end
      if guild_id == nil or tonumber(item.guild_id) == tonumber(guild_id) then
        table.insert(records, { id = record_id, item = item })
      end
    end
  end
  return records
end

function ReplayLogger:read_recent_indexed(limit, guild_id)
  local safe_limit = math.max(1, tonumber(limit) or 1)
  local records = self:_iter_records(guild_id)
  local result = {}
  for i = #records, math.max(1, #records - safe_limit + 1), -1 do
    local item = records[i]
    table.insert(result, { item.id, item.item })
  end
  return result
end

function ReplayLogger:get_by_index(record_id, guild_id)
  local target = tonumber(record_id)
  if not target or target <= 0 then
    return nil
  end
  local records = self:_iter_records(guild_id)
  for _, item in ipairs(records) do
    if item.id == target then
      return item.item
    end
    if item.id > target then
      break
    end
  end
  return nil
end

return ReplayLogger
