local SQL = require('src.sqlite')

local BanStore = {}
BanStore.__index = BanStore

function BanStore.new(path)
  local self = setmetatable({}, BanStore)
  self.path = path
  self.db = nil
  return self
end

function BanStore:initialize()
  self.db = SQL.open(self.path)
  SQL.exec(self.db, [[
    CREATE TABLE IF NOT EXISTS bot_banned_users (
      guild_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      banned_by INTEGER,
      reason TEXT,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (guild_id, user_id)
    )
  ]])
  SQL.exec(self.db, [[
    CREATE INDEX IF NOT EXISTS idx_bot_banned_users_guild_user
    ON bot_banned_users (guild_id, user_id)
  ]])
end

function BanStore:_require_db()
  if self.db == nil then
    error('BanStore is not initialized')
  end
  return self.db
end

function BanStore:ban_user(guild_id, user_id, banned_by, reason)
  local db = self:_require_db()
  local existed_rows = SQL.query(
    db,
    [[
      SELECT 1
      FROM bot_banned_users
      WHERE guild_id = ? AND user_id = ?
      LIMIT 1
    ]],
    guild_id,
    user_id
  )
  local existed = existed_rows[1] ~= nil

  SQL.run(
    db,
    [[
      INSERT INTO bot_banned_users (guild_id, user_id, banned_by, reason)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(guild_id, user_id) DO UPDATE SET
        banned_by = excluded.banned_by,
        reason = excluded.reason,
        updated_at = CURRENT_TIMESTAMP
    ]],
    guild_id,
    user_id,
    banned_by,
    reason
  )
  return not existed
end

function BanStore:unban_user(guild_id, user_id)
  local db = self:_require_db()
  local changes = SQL.run(
    db,
    'DELETE FROM bot_banned_users WHERE guild_id = ? AND user_id = ?',
    guild_id,
    user_id
  )
  return changes > 0
end

function BanStore:is_user_banned(guild_id, user_id)
  local db = self:_require_db()
  local rows = SQL.query(
    db,
    [[
      SELECT 1
      FROM bot_banned_users
      WHERE guild_id = ? AND user_id = ?
      LIMIT 1
    ]],
    guild_id,
    user_id
  )
  return rows[1] ~= nil
end

function BanStore:close()
  if self.db then
    self.db:close()
    self.db = nil
  end
end

return BanStore
