local sqlite3 = require "lsqlite3"
local Bus = require "prailude.bus"
local config = require "prailude.config"

local subdbs = {
  require "prailude.db.sqlite-tc.peer",
  require "prailude.db.sqlite-tc.block",
  require "prailude.db.sqlite-tc.blockwalker",
  require "prailude.db.sqlite-tc.frontier",
  require "prailude.db.sqlite-tc.account",
  require "prailude.db.sqlite-tc.kv",
}

local default_db
local dbs = {}
local DB = {}

function DB.pragma(db, pragma_list)
  for pragma, val in pairs(pragma_list) do
    if val == false then
      val = "OFF"
    elseif val == true then
      val = "ON"
    elseif val == nil then
      error("Invalid nil PRAGMA " .. pragma)
    end
    assert(db:exec(("PRAGMA %s = %s"):format(pragma, tostring(val))) == sqlite3.OK, "PRAGMA " .. pragma .. " error: " .. db:errmsg())
  end
end

function DB.open(name, opt)
  assert(not dbs[name], "db with name " .. name .. " already exists")
  local db, err_code, err_msg = sqlite3.open(config.data.path.."/"..(opt.db_file or name..".db"))
  if not db then
    error("error opening db  " .. name .. ": " .. (err_msg or err_code))
  end
  DB.pragma(db, opt.pragma)
  dbs[name]=db
  return db
end

function DB.db(name)
  if name then
    return assert(dbs[name])
  else
    return default_db
  end
end

function DB.transaction(db, fn)
  if not fn and type(db)=="function" then
    db, fn = default_db, db
  end
  
  assert(db:exec("BEGIN EXCLUSIVE TRANSACTION") == sqlite3.OK, db:errmsg())
  fn()
  local ok = db:exec("COMMIT TRANSACTION") == sqlite3.OK
  if ok then
    return db:total_changes()
  else
    return nil, db:errmsg()
  end
end

function DB.first_row(query)
  local f, t = default_db:nrows(query)
  return f(t)
end

function DB.first_result(query)
  local f, t = default_db:urows(query)
  return f(t)
end

function DB.initialize()
  --opt = opt or {}
  local db = DB.open("nano", {
    pragma = {
      synchronous = false, --don't really care if the db lags behind on crash
      journal_mode = "TRUNCATE",
      temp_store = "FILE",
      foreign_keys = "OFF",
      locking_mode = "EXCLUSIVE",
      cache_size = "-400000", --200MB max cachesize
      page_size = 16384,
    }
  })
  default_db = db
  assert(db:exec("ATTACH DATABASE ':memory:' as mem") == sqlite3.OK, db:errmsg())
  assert(db:exec("ATTACH DATABASE '".. config.data.path .."/tmp.db' as disktmp") == sqlite3.OK, db:errmsg())
  DB.pragma(db, {
    ["disktmp.synchronous"] = false, --don't really care if the db lags behind on crash
    ["disktmp.journal_mode"] = false,
    ["disktmp.foreign_keys"] = false,
    ["disktmp.page_size"] = 16384
  })
  
  for _, subdb in ipairs(subdbs) do
    subdb.initialize(db)
  end
  Bus.sub("shutdown", DB.shutdown)
end
  
function DB.shutdown()
  for _, subdb in ipairs(subdbs) do
    if subdb.shutdown then
      subdb.shutdown()
    end
  end
  for _, db in ipairs(dbs) do
    db:close()
  end
end

return DB
