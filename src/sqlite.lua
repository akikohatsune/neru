local sqlite3 = require('lsqlite3')
local utils = require('src.utils')

local M = {}

local function _format_error(db, prefix)
  local msg = db and db:errmsg() or 'unknown sqlite error'
  return string.format('%s: %s', prefix, msg)
end

function M.open(path)
  utils.ensure_parent_dir(path)
  local db = sqlite3.open(path)
  if not db then
    error('Unable to open sqlite database: ' .. tostring(path))
  end

  local rc1 = db:exec('PRAGMA journal_mode=WAL;')
  if rc1 ~= sqlite3.OK then
    error(_format_error(db, 'Failed to set journal_mode=WAL'))
  end

  local rc2 = db:exec('PRAGMA synchronous=NORMAL;')
  if rc2 ~= sqlite3.OK then
    error(_format_error(db, 'Failed to set synchronous=NORMAL'))
  end

  return db
end

function M.exec(db, sql)
  local rc = db:exec(sql)
  if rc ~= sqlite3.OK then
    error(_format_error(db, 'SQL exec failed'))
  end
end

function M.run(db, sql, ...)
  local stmt = db:prepare(sql)
  if not stmt then
    error(_format_error(db, 'SQL prepare failed'))
  end

  local bind_rc = stmt:bind_values(...)
  if bind_rc ~= sqlite3.OK then
    stmt:finalize()
    error(_format_error(db, 'SQL bind failed'))
  end

  local step_rc = stmt:step()
  if step_rc ~= sqlite3.DONE and step_rc ~= sqlite3.ROW then
    stmt:finalize()
    error(_format_error(db, 'SQL step failed'))
  end

  stmt:finalize()
  return db:changes()
end

function M.query(db, sql, ...)
  local stmt = db:prepare(sql)
  if not stmt then
    error(_format_error(db, 'SQL prepare failed'))
  end

  local bind_rc = stmt:bind_values(...)
  if bind_rc ~= sqlite3.OK then
    stmt:finalize()
    error(_format_error(db, 'SQL bind failed'))
  end

  local rows = {}
  while true do
    local rc = stmt:step()
    if rc == sqlite3.ROW then
      table.insert(rows, stmt:get_values())
    elseif rc == sqlite3.DONE then
      break
    else
      stmt:finalize()
      error(_format_error(db, 'SQL query step failed'))
    end
  end

  stmt:finalize()
  return rows
end

return M
