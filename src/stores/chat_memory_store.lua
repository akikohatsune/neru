local SQL = require('src.sqlite')

local ChatMemoryStore = {}
ChatMemoryStore.__index = ChatMemoryStore

function ChatMemoryStore.new(path, max_history_turns)
  local self = setmetatable({}, ChatMemoryStore)
  self.path = path
  self.max_messages = math.max(2, max_history_turns * 2)
  self.db = nil
  return self
end

function ChatMemoryStore:initialize()
  self.db = SQL.open(self.path)
  SQL.exec(self.db, [[
    CREATE TABLE IF NOT EXISTS chat_memory (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      channel_id INTEGER NOT NULL,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  ]])
  SQL.exec(self.db, [[
    CREATE INDEX IF NOT EXISTS idx_chat_memory_channel_id_id
    ON chat_memory (channel_id, id)
  ]])
end

function ChatMemoryStore:_require_db()
  if self.db == nil then
    error('ChatMemoryStore is not initialized')
  end
  return self.db
end

function ChatMemoryStore:append_message(channel_id, role, content)
  if role ~= 'user' and role ~= 'assistant' then
    error('Invalid role: ' .. tostring(role))
  end

  local db = self:_require_db()
  SQL.run(
    db,
    'INSERT INTO chat_memory (channel_id, role, content) VALUES (?, ?, ?)',
    channel_id,
    role,
    content
  )
  self:_trim_channel(channel_id)
end

function ChatMemoryStore:get_history(channel_id)
  local db = self:_require_db()
  local rows = SQL.query(
    db,
    [[
      SELECT role, content
      FROM chat_memory
      WHERE channel_id = ?
      ORDER BY id DESC
      LIMIT ?
    ]],
    channel_id,
    self.max_messages
  )

  local result = {}
  for idx = #rows, 1, -1 do
    local row = rows[idx]
    table.insert(result, {
      role = row[1],
      content = row[2],
    })
  end
  return result
end

function ChatMemoryStore:clear_channel(channel_id)
  local db = self:_require_db()
  SQL.run(db, 'DELETE FROM chat_memory WHERE channel_id = ?', channel_id)
end

function ChatMemoryStore:prune_inactive_channels(idle_seconds)
  if idle_seconds <= 0 then
    return
  end
  local db = self:_require_db()
  SQL.run(
    db,
    [[
      DELETE FROM chat_memory
      WHERE channel_id IN (
        SELECT channel_id
        FROM chat_memory
        GROUP BY channel_id
        HAVING MAX(created_at) < datetime('now', ?)
      )
    ]],
    string.format('-%d seconds', idle_seconds)
  )
end

function ChatMemoryStore:_trim_channel(channel_id)
  local db = self:_require_db()
  local rows = SQL.query(
    db,
    [[
      SELECT id
      FROM chat_memory
      WHERE channel_id = ?
      ORDER BY id DESC
      LIMIT 1 OFFSET ?
    ]],
    channel_id,
    self.max_messages - 1
  )
  if not rows[1] then
    return
  end

  local cutoff_id = rows[1][1]
  SQL.run(
    db,
    'DELETE FROM chat_memory WHERE channel_id = ? AND id < ?',
    channel_id,
    cutoff_id
  )
end

function ChatMemoryStore:close()
  if self.db then
    self.db:close()
    self.db = nil
  end
end

return ChatMemoryStore
