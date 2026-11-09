# Requires the pinned current-master sqlite3 package, or CRuby + sqlite3 gem.
require 'spnl_schema/sqlite_adapter'
DB=SpnlSchema::SQLiteAdapter.new(ENV.fetch('SPNL_DATABASE','demo.sqlite3'))
DB.exec('CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY,email TEXT NOT NULL UNIQUE,name TEXT NOT NULL)',[])
DB.exec('INSERT OR IGNORE INTO users(id,email,name) VALUES(?,?,?)',[1,'alice@example.com','Alice'])
require_relative '../app'
begin
  Demo.run
ensure
  DB.close
end
