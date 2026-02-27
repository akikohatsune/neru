return {
  name = 'neru-lua-binary',
  version = '1.0.0',
  description = 'Neru bot refactor in Lua, packaged as single binary via lit/luvi',
  main = 'main.lua',
  dependencies = {
    'SinisterRectus/discordia',
    'creationix/coro-http',
    'luvit/json',
  },
}
