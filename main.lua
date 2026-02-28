package.path = table.concat({
  package.path,
  'deps/?.lua',
  'deps/?/init.lua',
  'deps/?/?.lua',
  'deps/discordia/libs/?.lua',
  'deps/discordia/libs/?/init.lua',
  'deps/secure-socket/?.lua',
  'deps/sha1/?.lua',
}, ';')

if not package.preload['./package.lua'] then
  package.preload['./package.lua'] = function()
    return require('discordia/package')
  end
end

local discordia = require('discordia')
local uv = require('uv')

local Config = require('src.config')
local Utils = require('src.utils')
local LLMClient = require('src.llm_client')
local ReplayLogger = require('src.replay_logger')
local ChatMemoryStore = require('src.stores.chat_memory_store')
local BanStore = require('src.stores.ban_store')
local CallNamesStore = require('src.stores.callnames_store')

local settings = Config.load()

local client = discordia.Client({
  cacheAllMembers = false,
  gatewayIntents = 53608447,
})

local llm = LLMClient.new(settings)
local replay_logger = ReplayLogger.new(settings.chat_replay_log_path)
local chat_store = ChatMemoryStore.new(settings.chat_memory_db_path, settings.max_history)
local ban_store = BanStore.new(settings.ban_db_path)
local callnames_store = CallNamesStore.new(settings.callnames_db_path)

chat_store:initialize()
ban_store:initialize()
callnames_store:initialize()
replay_logger:initialize()

local state = {
  is_terminated = false,
  deleted_map = {},
  deleted_order = {},
  deleted_limit = 2000,
}

local function is_owner(user_id)
  if settings.bot_owner_id <= 0 then
    return false
  end
  return tonumber(user_id) == tonumber(settings.bot_owner_id)
end

local function track_deleted_message(message_id)
  local key = tostring(message_id)
  if state.deleted_map[key] then
    return
  end
  state.deleted_map[key] = true
  table.insert(state.deleted_order, key)
  while #state.deleted_order > state.deleted_limit do
    local expired = table.remove(state.deleted_order, 1)
    state.deleted_map[expired] = nil
  end
end

local function is_deleted(message_id)
  return state.deleted_map[tostring(message_id)] == true
end

local function active_chat_model()
  if settings.provider == 'gemini' then
    return settings.gemini_model
  end
  if settings.provider == 'groq' then
    return settings.groq_model
  end
  if settings.provider == 'openai' then
    return settings.openai_model
  end
  return 'unknown'
end

local function normalize_prompt(prompt, fallback)
  local trimmed = Utils.trim(prompt)
  if trimmed == '' then
    return fallback
  end
  return trimmed
end

local function latex_to_plain_math(text)
  local out = tostring(text or '')
  if not out:match('%$') and not out:match('\\') then
    return out
  end

  out = out:gsub('\\left', ''):gsub('\\right', '')
  out = out:gsub('\\times', '*'):gsub('\\cdot', '*')
  out = out:gsub('\\div', '/')
  out = out:gsub('\\pm', '+/-')
  out = out:gsub('\\neq', '!=')
  out = out:gsub('\\leq', '<='):gsub('\\geq', '>=')
  out = out:gsub('\\approx', '~=')
  out = out:gsub('\\pi', 'pi')

  for _ = 1, 5 do
    local updated, count = out:gsub('\\frac%s*{([^{}]+)}%s*{([^{}]+)}', '(%1)/(%2)')
    out = updated
    if count == 0 then
      break
    end
  end

  for _ = 1, 5 do
    local updated, count = out:gsub('\\sqrt%s*{([^{}]+)}', 'sqrt(%1)')
    out = updated
    if count == 0 then
      break
    end
  end

  out = out:gsub('\\text%s*{([^{}]+)}', '%1')
  out = out:gsub('\\%(', ''):gsub('\\%)', '')
  out = out:gsub('\\%[', ''):gsub('\\%]', '')
  out = out:gsub('%$%$', ''):gsub('%$', '')
  out = out:gsub('%s+', ' ')
  return Utils.trim(out)
end

local function strip_private_reasoning(text)
  local out = tostring(text or '')

  local tagged_blocks = {
    '<%s*[Tt][Hh][Ii][Nn][Kk]%s*>[%s%S]-<%s*/%s*[Tt][Hh][Ii][Nn][Kk]%s*>',
    '<%s*[Aa][Nn][Aa][Ll][Yy][Ss][Ii][Ss]%s*>[%s%S]-<%s*/%s*[Aa][Nn][Aa][Ll][Yy][Ss][Ii][Ss]%s*>',
    '<%s*[Rr][Ee][Aa][Ss][Oo][Nn][Ii][Nn][Gg]%s*>[%s%S]-<%s*/%s*[Rr][Ee][Aa][Ss][Oo][Nn][Ii][Nn][Gg]%s*>',
  }

  for _, pattern in ipairs(tagged_blocks) do
    while true do
      local updated, count = out:gsub(pattern, '')
      out = updated
      if count == 0 then
        break
      end
    end
  end

  local fenced_blocks = {
    '```%s*[Tt][Hh][Ii][Nn][Kk][^\n]*\n[%s%S]-```',
    '```%s*[Aa][Nn][Aa][Ll][Yy][Ss][Ii][Ss][^\n]*\n[%s%S]-```',
    '```%s*[Rr][Ee][Aa][Ss][Oo][Nn][Ii][Nn][Gg][^\n]*\n[%s%S]-```',
  }
  for _, pattern in ipairs(fenced_blocks) do
    while true do
      local updated, count = out:gsub(pattern, '')
      out = updated
      if count == 0 then
        break
      end
    end
  end

  out = out:gsub('\r', '')
  out = out:gsub('\n%s*\n%s*\n+', '\n\n')
  return Utils.trim(out)
end

local function normalize_model_reply(text)
  local sanitized = strip_private_reasoning(text)
  return latex_to_plain_math(sanitized)
end

local function send_reply(target_message, content)
  return target_message:reply({
    content = content,
    allowedMentions = { repliedUser = false },
  })
end

local function send_long_message(target_message, text)
  local sanitized = Utils.sanitize_mentions(text)
  local max_len = math.min(1900, settings.max_reply_chars)
  local chunks = Utils.chunk_text(sanitized, max_len)
  for idx, chunk in ipairs(chunks) do
    if idx == 1 then
      send_reply(target_message, chunk)
    else
      target_message.channel:send(chunk)
    end
  end
end

local function is_banned_user(guild_id, user_id)
  if not guild_id then
    return false
  end
  return ban_store:is_user_banned(guild_id, user_id)
end

local function build_replay_payload(action, guild_id)
  local action_value = Utils.trim(action):lower()
  if action_value == '' then
    action_value = 'ls'
  end

  if action_value == 'ls' then
    local records = replay_logger:read_recent_indexed(30, guild_id)
    if #records == 0 then
      return 'No chat replay logs yet.'
    end
    local lines = { 'Replay logs (newest first):' }
    for _, pair in ipairs(records) do
      local record_id = pair[1]
      local item = pair[2]
      local prompt = tostring(item.prompt or ''):gsub('[\r\n]+', ' ')
      if #prompt > 70 then
        prompt = prompt:sub(1, 67) .. '...'
      end
      table.insert(lines,
        string.format(
          '[%d] %s | %s (%s) | %s | %s',
          record_id,
          tostring(item.ts_utc or '?'),
          tostring(item.user_display or 'unknown'),
          tostring(item.user_id or '?'),
          tostring(item.trigger or '?'),
          prompt
        )
      )
    end
    table.insert(lines, 'Use ' .. settings.command_prefix .. 'replayneru <id> to view full details.')
    return table.concat(lines, '\n')
  end

  local record_id = tonumber(action_value)
  if not record_id then
    error('Usage: ' .. settings.command_prefix .. 'replayneru ls or ' .. settings.command_prefix .. 'replayneru <id>')
  end

  local item = replay_logger:get_by_index(record_id, guild_id)
  if not item then
    return 'Replay id ' .. tostring(record_id) .. ' not found.'
  end

  local lines = {
    'Replay #' .. tostring(record_id),
    'Time: ' .. tostring(item.ts_utc or '?'),
    string.format('Guild: %s (%s)', tostring(item.guild_name or '?'), tostring(item.guild_id or '?')),
    string.format('Channel: %s (%s)', tostring(item.channel_name or '?'), tostring(item.channel_id or '?')),
    string.format('User: %s (%s)', tostring(item.user_display or '?'), tostring(item.user_id or '?')),
    'Trigger: ' .. tostring(item.trigger or '?'),
    'Reply length: ' .. tostring(item.reply_length or '?'),
    'Prompt:',
    tostring(item.prompt or '(empty)'),
  }
  return table.concat(lines, '\n')
end

local function extract_images_from_message(message)
  local images = {}
  if not message or not message.attachments then
    return images
  end

  local function consume_attachment(attachment)
    local mime_type = tostring(attachment.contentType or attachment.content_type or ''):lower()
    local filename = tostring(attachment.filename or 'file')
    local size = tonumber(attachment.size or 0) or 0
    local url = attachment.url

    if mime_type == '' then
      local ext = filename:match('%.([A-Za-z0-9]+)$')
      if ext then
        local lowered = ext:lower()
        if lowered == 'png' then
          mime_type = 'image/png'
        elseif lowered == 'jpg' or lowered == 'jpeg' then
          mime_type = 'image/jpeg'
        elseif lowered == 'gif' then
          mime_type = 'image/gif'
        elseif lowered == 'webp' then
          mime_type = 'image/webp'
        end
      end
    end

    if mime_type:sub(1, 6) ~= 'image/' then
      return
    end

    if size > settings.image_max_bytes then
      error("Image '" .. filename .. "' exceeds limit of " .. tostring(settings.image_max_bytes) .. ' bytes')
    end

    local data_b64 = nil
    if url then
      local bytes, err = Utils.http_get_bytes(url)
      if bytes then
        data_b64 = Utils.base64_encode(bytes)
      elseif settings.provider == 'gemini' then
        error('Failed to read image bytes: ' .. tostring(err))
      end
    end

    table.insert(images, {
      mime_type = mime_type,
      data_b64 = data_b64,
      url = url,
    })
  end

  if message.attachments.iter then
    for attachment in message.attachments:iter() do
      consume_attachment(attachment)
    end
  else
    for _, attachment in pairs(message.attachments) do
      consume_attachment(attachment)
    end
  end

  return images
end

local function apply_call_preferences_to_prompt(prompt, guild_id, user_id)
  if not guild_id or not user_id then
    return prompt
  end
  local user_calls_neru, neru_calls_user = callnames_store:get_user_call_preferences(guild_id, user_id)
  if not user_calls_neru and not neru_calls_user then
    return prompt
  end
  local parts = { '[call_profile_context]' }
  if user_calls_neru then
    table.insert(parts, 'user calls Neru: ' .. user_calls_neru)
  end
  if neru_calls_user then
    table.insert(parts, 'Neru calls user: ' .. neru_calls_user)
  end
  table.insert(parts, '[message_content]')
  table.insert(parts, prompt)
  return table.concat(parts, '\n')
end

local function memory_user_entry(prompt, image_count)
  if image_count <= 0 then
    return prompt
  end
  return prompt .. '\n[attached_images=' .. tostring(image_count) .. ']'
end

local function run_chat_and_reply_impl(message, prompt, fallback_prompt, trigger)
  if is_deleted(message.id) then
    return
  end

  local effective_prompt = normalize_prompt(prompt, fallback_prompt)
  local channel_id = message.channel.id
  local guild_id = message.guild and message.guild.id or nil
  local user_id = message.author.id

  local images = extract_images_from_message(message)
  local prompt_for_llm = apply_call_preferences_to_prompt(effective_prompt, guild_id or 0, user_id)
  local history = chat_store:get_history(channel_id)
  local llm_messages = {}
  for _, item in ipairs(history) do
    table.insert(llm_messages, {
      role = item.role,
      content = item.content,
    })
  end
  table.insert(llm_messages, {
    role = 'user',
    content = prompt_for_llm,
    images = images,
  })

  message.channel:broadcastTyping()
  local reply = normalize_model_reply(llm:generate(llm_messages))

  chat_store:append_message(channel_id, 'user', memory_user_entry(effective_prompt, #images))
  chat_store:append_message(channel_id, 'assistant', reply)

  local guild_name = message.guild and message.guild.name or nil
  local channel_name = message.channel and message.channel.name or nil
  replay_logger:log_chat({
    guild_id = guild_id,
    guild_name = guild_name,
    channel_id = channel_id,
    channel_name = channel_name,
    user_id = user_id,
    user_name = message.author.username,
    user_display = message.member and message.member.nickname or message.author.username,
    trigger = trigger,
    prompt = effective_prompt,
    reply_length = #reply,
  })

  if is_deleted(message.id) then
    return
  end
  send_long_message(message, reply)
end

local function run_chat_and_reply(message, prompt, fallback_prompt, trigger)
  local ok, err = pcall(function()
    run_chat_and_reply_impl(message, prompt, fallback_prompt, trigger)
  end)
  if ok then
    return
  end

  local effective_prompt = normalize_prompt(prompt, fallback_prompt)
  local guild_id = message.guild and message.guild.id or nil
  local guild_name = message.guild and message.guild.name or nil
  local channel_name = message.channel and message.channel.name or nil
  local user_display = message.member and message.member.nickname or message.author.username

  local log_ok, log_err = pcall(function()
    replay_logger:log_error({
      guild_id = guild_id,
      guild_name = guild_name,
      channel_id = message.channel.id,
      channel_name = channel_name,
      user_id = message.author.id,
      user_name = message.author.username,
      user_display = user_display,
      trigger = trigger,
      prompt = effective_prompt,
      error = tostring(err),
    })
  end)
  if not log_ok then
    print('[chat] failed to log error: ' .. tostring(log_err))
  end

  print('[chat] run_chat_and_reply failed: ' .. tostring(err))
  if not is_deleted(message.id) then
    send_reply(message, 'i overload!')
  end
end

local function maybe_cleanup_memory()
  if settings.memory_idle_ttl_seconds <= 0 then
    return
  end
  local ok, err = pcall(function()
    chat_store:prune_inactive_channels(settings.memory_idle_ttl_seconds)
  end)
  if not ok then
    print('[memory-cleanup] error: ' .. tostring(err))
  end
end

local function set_presence()
  if not settings.rpc_enabled then
    print('Discord RPC presence: disabled')
    return
  end

  local ok_status = pcall(function()
    client:setStatus(settings.rpc_status)
  end)

  local activity_type = settings.rpc_activity_type
  if activity_type == 'none' then
    print('Discord RPC presence applied: status=' .. settings.rpc_status .. ', type=none')
    return
  end

  local activity_payload = {
    name = settings.rpc_activity_name,
    type = 0,
  }
  if activity_type == 'listening' then
    activity_payload.type = 2
  elseif activity_type == 'watching' then
    activity_payload.type = 3
  elseif activity_type == 'competing' then
    activity_payload.type = 5
  elseif activity_type == 'streaming' then
    activity_payload.type = 1
    activity_payload.url = settings.rpc_activity_url
  else
    activity_payload.type = 0
  end

  local ok_activity = pcall(function()
    client:setActivity(activity_payload)
  end)

  if not ok_status then
    print('[rpc] failed to apply status: ' .. tostring(settings.rpc_status))
  end
  if not ok_activity then
    print('[rpc] failed to apply activity')
  end

  print(
    'Discord RPC presence applied: status=' .. settings.rpc_status
      .. ', type=' .. activity_type
      .. ', name=' .. settings.rpc_activity_name
  )
end

local function handle_command(message, command_name, args)
  local guild_id = message.guild and message.guild.id or nil
  local author_id = message.author.id

  if command_name == 'chat' or command_name == 'ask' then
    if is_banned_user(guild_id, author_id) then
      send_reply(message, 'You are banned from using the AI bot in this server.')
      return true
    end
    if state.is_terminated then
      send_reply(message, 'Terminated mode enabled. Use ' .. settings.command_prefix .. 'terminated off')
      return true
    end
    run_chat_and_reply(message, args, 'hi', 'command')
    return true
  end

  if command_name == 'clearmemo' or command_name == 'resetchat' then
    chat_store:clear_channel(message.channel.id)
    send_reply(message, 'Cleared short-term memory for this channel.')
    return true
  end

  if command_name == 'terminated' then
    local mode = Utils.trim(args):lower()
    if mode == '' then
      mode = 'on'
    end
    if mode == 'on' or mode == '1' or mode == 'true' then
      state.is_terminated = true
      send_reply(message, 'Terminated mode enabled: bot will stop replying to chat and mentions.')
      return true
    end
    if mode == 'off' or mode == '0' or mode == 'false' then
      state.is_terminated = false
      send_reply(message, 'Terminated mode disabled: bot can reply normally again.')
      return true
    end
    if mode == 'status' then
      send_reply(message, 'Terminated status: `' .. (state.is_terminated and 'ON' or 'OFF') .. '`')
      return true
    end
    send_reply(message, 'Usage: ' .. settings.command_prefix .. 'terminated on|off|status')
    return true
  end

  if command_name == 'provider' then
    send_reply(
      message,
      'Current provider: `' .. settings.provider
        .. '` | Model: `' .. active_chat_model()
        .. '` | Approval provider: `gemini` | Approval model: `' .. settings.gemini_approval_model
        .. '` | Chat DB: `' .. settings.chat_memory_db_path
        .. '` | Ban DB: `' .. settings.ban_db_path
        .. '` | Callnames DB: `' .. settings.callnames_db_path
        .. '` | Idle TTL: `' .. tostring(settings.memory_idle_ttl_seconds)
        .. 's` | Image limit: `' .. tostring(settings.image_max_bytes)
        .. '` bytes | Reply chunk size: `' .. tostring(settings.max_reply_chars)
        .. '` chars | Terminated: `' .. tostring(state.is_terminated) .. '`'
    )
    return true
  end

  if command_name == 'replayneru' then
    if not is_owner(author_id) then
      send_reply(message, 'Only the bot owner can use this command.')
      return true
    end
    local ok, payload_or_err = pcall(function()
      return build_replay_payload(args, guild_id)
    end)
    if not ok then
      send_reply(message, tostring(payload_or_err))
      return true
    end
    send_long_message(message, payload_or_err)
    return true
  end

  if command_name == 'ban' then
    if not guild_id then
      send_reply(message, 'This command can only be used in a server.')
      return true
    end
    if not is_owner(author_id) then
      send_reply(message, 'Only the bot owner can use this command.')
      return true
    end

    local target_token, reason = args:match('^(%S+)%s*(.*)$')
    local target_id = target_token and Utils.parse_user_id(target_token) or nil
    if not target_id then
      send_reply(message, 'Usage: ' .. settings.command_prefix .. 'ban @user [reason]')
      return true
    end

    local created = ban_store:ban_user(guild_id, target_id, author_id, Utils.trim(reason))
    if created then
      send_reply(message, 'Banned <@' .. tostring(target_id) .. '> from using the AI bot.')
    else
      send_reply(message, 'Updated ban entry for <@' .. tostring(target_id) .. '>.')
    end
    return true
  end

  if command_name == 'removeban' then
    if not guild_id then
      send_reply(message, 'This command can only be used in a server.')
      return true
    end
    if not is_owner(author_id) then
      send_reply(message, 'Only the bot owner can use this command.')
      return true
    end

    local target_id = Utils.parse_user_id(args)
    if not target_id then
      send_reply(message, 'Usage: ' .. settings.command_prefix .. 'removeban @user')
      return true
    end

    local removed = ban_store:unban_user(guild_id, target_id)
    if removed then
      send_reply(message, 'Removed AI-bot ban for <@' .. tostring(target_id) .. '>.')
    else
      send_reply(message, '<@' .. tostring(target_id) .. '> is not currently in the ban list.')
    end
    return true
  end

  if command_name == 'ucallneru' or command_name == 'callneru' then
    local value = Utils.trim(args)
    if value == '' then
      send_reply(message, 'Name cannot be empty.')
      return true
    end
    if #value > 60 then
      send_reply(message, 'Name is too long (max 60 characters).')
      return true
    end

    local ok, approved_or_err = pcall(function()
      return llm:approve_call_name('user_calls_neru', value)
    end)
    if not ok then
      send_reply(message, 'Unable to run call-name approval right now: `' .. tostring(approved_or_err) .. '`')
      return true
    end
    if not approved_or_err then
      send_reply(message, 'Call-name was rejected by approval (`no`).')
      return true
    end

    callnames_store:set_user_calls_neru(guild_id or 0, author_id, value)
    send_reply(message, 'Saved: you call Neru `' .. value .. '`.')
    return true
  end

  if command_name == 'nerucallu' or command_name == 'callme' then
    local value = Utils.trim(args)
    if value == '' then
      send_reply(message, 'Name cannot be empty.')
      return true
    end
    if #value > 60 then
      send_reply(message, 'Name is too long (max 60 characters).')
      return true
    end

    local ok, approved_or_err = pcall(function()
      return llm:approve_call_name('neru_calls_user', value)
    end)
    if not ok then
      send_reply(message, 'Unable to run call-name approval right now: `' .. tostring(approved_or_err) .. '`')
      return true
    end
    if not approved_or_err then
      send_reply(message, 'Call-name was rejected by approval (`no`).')
      return true
    end

    callnames_store:set_neru_calls_user(guild_id or 0, author_id, value)
    send_reply(message, 'Saved: Neru will call you `' .. value .. '`.')
    return true
  end

  if command_name == 'nerumention' or command_name == 'callprofile' then
    local user_calls_neru, neru_calls_user = callnames_store:get_user_call_preferences(guild_id or 0, author_id)
    local display_name = (message.member and message.member.nickname) or message.author.username
    send_reply(
      message,
      'Current call profile | You call Neru: `'
        .. tostring(user_calls_neru or 'Neru')
        .. '` | Neru calls you: `'
        .. tostring(neru_calls_user or display_name)
        .. '`'
    )
    return true
  end

  return false
end

local function extract_command_with_fallback(content)
  local command_name, args = Utils.extract_prefixed_command(content, settings.command_prefix)
  if command_name then
    return command_name, args
  end
  if settings.command_prefix ~= '!' then
    return Utils.extract_prefixed_command(content, '!')
  end
  return nil, nil
end

local function is_reply_to_bot(message)
  if not message then
    return false
  end

  local referenced = message.referencedMessage
  if referenced and referenced.author and referenced.author.id then
    return tostring(referenced.author.id) == tostring(client.user.id)
  end

  local reference = message.reference or message.messageReference
  if not reference then
    return false
  end

  local reference_id = reference.message or reference.messageId or reference.id
  if not reference_id or not message.channel or not message.channel.getMessage then
    return false
  end

  local ok, reply_target = pcall(function()
    return message.channel:getMessage(reference_id)
  end)
  if not ok or not reply_target or not reply_target.author or not reply_target.author.id then
    return false
  end
  return tostring(reply_target.author.id) == tostring(client.user.id)
end

client:on('ready', function()
  set_presence()
  print('Logged in as ' .. tostring(client.user.tag) .. ' (ID: ' .. tostring(client.user.id) .. ')')
  print('Command prefix: ' .. settings.command_prefix .. ' (also accepts !)')
  print('Provider: ' .. settings.provider)
  print('Model: ' .. active_chat_model())
  print('Approval provider: gemini (fixed)')
  print('Approval model: ' .. settings.gemini_approval_model)
  print('System rules MD: ' .. settings.system_rules_md)
  print('Chat replay log: ' .. settings.chat_replay_log_path)
  print('Chat memory DB: ' .. settings.chat_memory_db_path)
  print('Ban DB: ' .. settings.ban_db_path)
  print('Callnames DB: ' .. settings.callnames_db_path)
  print('Memory idle TTL: ' .. tostring(settings.memory_idle_ttl_seconds) .. 's')
  print('Image max bytes: ' .. tostring(settings.image_max_bytes))
  print('Max reply chars: ' .. tostring(settings.max_reply_chars))
end)

client:on('messageDelete', function(message)
  if message and message.id then
    track_deleted_message(message.id)
  end
end)

client:on('messageDeleteUncached', function(channel, id)
  if id then
    track_deleted_message(id)
  end
end)

client:on('messageCreate', function(message)
  if not message then
    return
  end

  local content = tostring(message.content or '')

  if is_deleted(message.id) then
    return
  end

  local inline_pattern = '^' .. settings.command_prefix:gsub('(%W)', '%%%1') .. 'replayneru(%d+)$'
  local replay_id = Utils.trim(content):match(inline_pattern)
  if replay_id and not message.author.bot then
    if not is_owner(message.author.id) then
      send_reply(message, 'Only the bot owner can use this command.')
      return
    end
    local payload = build_replay_payload(replay_id, message.guild and message.guild.id or nil)
    send_long_message(message, payload)
    return
  end

  local command_name, args = extract_command_with_fallback(content)
  if command_name then
    local handled = handle_command(message, command_name, args or '')
    if handled then
      return
    end
  end

  if message.author.bot then
    return
  end

  local guild_id = message.guild and message.guild.id or nil
  if is_banned_user(guild_id, message.author.id) then
    return
  end

  if state.is_terminated then
    return
  end

  local mention_plain = '<@' .. tostring(client.user.id) .. '>'
  local mention_nick = '<@!' .. tostring(client.user.id) .. '>'
  if content:find(mention_plain, 1, true) or content:find(mention_nick, 1, true) then
    local mention_text = content:gsub(mention_plain, ''):gsub(mention_nick, '')
    run_chat_and_reply(message, mention_text, 'hi', 'mention')
    return
  end

  if is_reply_to_bot(message) then
    run_chat_and_reply(message, content, 'hi', 'reply')
  end
end)

local cleanup_timer = uv.new_timer()
cleanup_timer:start(60000, 60000, function()
  local ok, err = pcall(maybe_cleanup_memory)
  if not ok then
    print('[memory-cleanup] timer error: ' .. tostring(err))
  end
end)

client:run('Bot ' .. settings.discord_token)
