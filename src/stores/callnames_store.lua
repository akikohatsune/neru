local SQL = require('src.sqlite')

local CallNamesStore = {}
CallNamesStore.__index = CallNamesStore

function CallNamesStore.new(path)
  local self = setmetatable({}, CallNamesStore)
  self.path = path
  self.db = nil
  return self
end

function CallNamesStore:initialize()
  self.db = SQL.open(self.path)
  SQL.exec(self.db, [[
    CREATE TABLE IF NOT EXISTS user_call_preferences (
      guild_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      user_calls_neru TEXT,
      neru_calls_user TEXT,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (guild_id, user_id)
    )
  ]])
  SQL.exec(self.db, [[
    CREATE INDEX IF NOT EXISTS idx_user_call_preferences_guild_user
    ON user_call_preferences (guild_id, user_id)
  ]])
  self:_migrate_legacy_miku_columns()
end

function CallNamesStore:_require_db()
  if self.db == nil then
    error('CallNamesStore is not initialized')
  end
  return self.db
end

function CallNamesStore:_list_columns()
  local db = self:_require_db()
  local rows = SQL.query(db, "PRAGMA table_info('user_call_preferences')")
  local columns = {}
  for _, row in ipairs(rows) do
    columns[tostring(row[2])] = true
  end
  return columns
end

function CallNamesStore:_migrate_legacy_miku_columns()
  local db = self:_require_db()
  local cols = self:_list_columns()

  if not cols.user_calls_neru then
    SQL.exec(db, 'ALTER TABLE user_call_preferences ADD COLUMN user_calls_neru TEXT')
  end
  if not cols.neru_calls_user then
    SQL.exec(db, 'ALTER TABLE user_call_preferences ADD COLUMN neru_calls_user TEXT')
  end

  cols = self:_list_columns()
  if cols.user_calls_miku then
    SQL.exec(db, [[
      UPDATE user_call_preferences
      SET user_calls_neru = COALESCE(user_calls_neru, user_calls_miku)
      WHERE user_calls_miku IS NOT NULL
    ]])
  end
  if cols.miku_calls_user then
    SQL.exec(db, [[
      UPDATE user_call_preferences
      SET neru_calls_user = COALESCE(neru_calls_user, miku_calls_user)
      WHERE miku_calls_user IS NOT NULL
    ]])
  end
end

function CallNamesStore:set_user_calls_neru(guild_id, user_id, call_name)
  local db = self:_require_db()
  SQL.run(
    db,
    [[
      INSERT INTO user_call_preferences (guild_id, user_id, user_calls_neru)
      VALUES (?, ?, ?)
      ON CONFLICT(guild_id, user_id) DO UPDATE SET
        user_calls_neru = excluded.user_calls_neru,
        updated_at = CURRENT_TIMESTAMP
    ]],
    guild_id,
    user_id,
    call_name
  )
end

function CallNamesStore:set_neru_calls_user(guild_id, user_id, call_name)
  local db = self:_require_db()
  SQL.run(
    db,
    [[
      INSERT INTO user_call_preferences (guild_id, user_id, neru_calls_user)
      VALUES (?, ?, ?)
      ON CONFLICT(guild_id, user_id) DO UPDATE SET
        neru_calls_user = excluded.neru_calls_user,
        updated_at = CURRENT_TIMESTAMP
    ]],
    guild_id,
    user_id,
    call_name
  )
end

function CallNamesStore:get_user_call_preferences(guild_id, user_id)
  local db = self:_require_db()
  local rows = SQL.query(
    db,
    [[
      SELECT user_calls_neru, neru_calls_user
      FROM user_call_preferences
      WHERE guild_id = ? AND user_id = ?
      LIMIT 1
    ]],
    guild_id,
    user_id
  )
  if not rows[1] then
    return nil, nil
  end
  return rows[1][1], rows[1][2]
end

function CallNamesStore:close()
  if self.db then
    self.db:close()
    self.db = nil
  end
end

return CallNamesStore
