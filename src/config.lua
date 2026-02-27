local utils = require('src.utils')

local DEFAULT_GEMINI_MODEL = 'gemini-3-flash'
local DEFAULT_GEMINI_APPROVAL_MODEL = 'gemini-3-flash'
local DEFAULT_OPENAI_MODEL = 'gpt-4o-mini'

local M = {}

local function load_dotenv(path)
  local env = {}
  if not utils.path_exists(path) then
    return env
  end
  local raw = utils.read_file(path) or ''
  for line in tostring(raw):gmatch('[^\r\n]+') do
    local trimmed = utils.trim(line)
    if trimmed ~= '' and trimmed:sub(1, 1) ~= '#' then
      local key, value = trimmed:match('^([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
      if key then
        if value:sub(1, 1) == '"' and value:sub(-1) == '"' then
          value = value:sub(2, -2)
        end
        env[key] = value
      end
    end
  end
  return env
end

local function get_env_str(name, default_value, file_env)
  local value = os.getenv(name)
  if (value == nil or value == '') and file_env then
    value = file_env[name]
  end
  if value == nil then
    return default_value
  end
  value = utils.trim(value)
  if value == '' then
    return default_value
  end
  return value
end

local function load_system_rules_prompt(path_value)
  if not utils.path_exists(path_value) then
    return ''
  end
  local rules = utils.trim(utils.read_file(path_value) or '')
  if rules == '' then
    return ''
  end
  return table.concat({
    'You must follow these extra system rules loaded from Markdown.',
    'Treat every rule as mandatory behavior.',
    'Rules source: ' .. path_value,
    'Rules Markdown:',
    rules,
  }, '\n')
end

function M.load()
  local file_env = load_dotenv('.env')

  local provider = get_env_str('LLM_PROVIDER', 'gemini', file_env):lower()
  if provider == 'chatgpt' then
    provider = 'openai'
  end
  if provider ~= 'gemini' and provider ~= 'groq' and provider ~= 'openai' then
    error('LLM_PROVIDER must be one of: gemini, groq, openai, chatgpt')
  end

  local discord_token = get_env_str('DISCORD_TOKEN', '', file_env)
  if discord_token == '' then
    error('Missing DISCORD_TOKEN')
  end

  local base_system_prompt = get_env_str(
    'SYSTEM_PROMPT',
    'You are Neru, a playful AI assistant on Discord. Default to English unless explicitly asked otherwise.',
    file_env
  )
  local system_rules_md = get_env_str('SYSTEM_RULES_MD', 'system_rules.md', file_env)
  local rules_prompt = load_system_rules_prompt(system_rules_md)
  local private_reasoning_guard = table.concat({
    'Never reveal internal reasoning or chain-of-thought.',
    'Do not output tags like <think>, <analysis>, <reasoning>, or hidden deliberation.',
    'Return only the final user-facing answer.',
  }, ' ')
  local full_system_prompt = base_system_prompt
  full_system_prompt = full_system_prompt .. '\n\n' .. private_reasoning_guard
  if rules_prompt ~= '' then
    full_system_prompt = full_system_prompt .. '\n\n' .. rules_prompt
  end

  local legacy_memory_db_path = get_env_str('MEMORY_DB_PATH', 'storage/db/chat_memory.db', file_env)
  local gemini_api_key = get_env_str('GEMINI_API_KEY', '', file_env)
  if gemini_api_key == '' then
    gemini_api_key = nil
  end
  local approval_gemini_api_key = get_env_str('APPROVAL_GEMINI_API_KEY', '', file_env)
  if approval_gemini_api_key == '' then
    approval_gemini_api_key = gemini_api_key
  end

  local groq_api_key = get_env_str('GROQ_API_KEY', '', file_env)
  if groq_api_key == '' then
    groq_api_key = nil
  end

  local openai_api_key = get_env_str('OPENAI_API_KEY', '', file_env)
  if openai_api_key == '' then
    openai_api_key = nil
  end

  local settings = {
    discord_token = discord_token,
    command_prefix = get_env_str('COMMAND_PREFIX', '!', file_env),
    rpc_enabled = utils.to_bool(get_env_str('RPC_ENABLED', 'true', file_env), true),
    rpc_status = get_env_str('RPC_STATUS', 'online', file_env):lower(),
    rpc_activity_type = get_env_str('RPC_ACTIVITY_TYPE', 'playing', file_env):lower(),
    rpc_activity_name = get_env_str('RPC_ACTIVITY_NAME', 'with AI chats', file_env),
    rpc_activity_url = get_env_str('RPC_ACTIVITY_URL', '', file_env),
    provider = provider,
    gemini_api_key = gemini_api_key,
    approval_gemini_api_key = approval_gemini_api_key,
    gemini_model = get_env_str('GEMINI_MODEL', DEFAULT_GEMINI_MODEL, file_env),
    gemini_approval_model = get_env_str('GEMINI_APPROVAL_MODEL', DEFAULT_GEMINI_APPROVAL_MODEL, file_env),
    groq_api_key = groq_api_key,
    groq_model = get_env_str('GROQ_MODEL', 'llama-3.3-70b-versatile', file_env),
    openai_api_key = openai_api_key,
    openai_model = get_env_str('OPENAI_MODEL', DEFAULT_OPENAI_MODEL, file_env),
    system_prompt = full_system_prompt,
    system_rules_md = system_rules_md,
    chat_replay_log_path = get_env_str('CHAT_REPLAY_LOG_PATH', 'storage/log/chat_replay.jsonl', file_env),
    chat_memory_db_path = get_env_str('CHAT_MEMORY_DB_PATH', legacy_memory_db_path, file_env),
    ban_db_path = get_env_str('BAN_DB_PATH', 'storage/db/ban_control.db', file_env),
    callnames_db_path = get_env_str('CALLNAMES_DB_PATH', 'storage/db/callnames.db', file_env),
    memory_idle_ttl_seconds = utils.to_int(get_env_str('MEMORY_IDLE_TTL_SECONDS', '300', file_env), 'MEMORY_IDLE_TTL_SECONDS', 300, 0),
    image_max_bytes = utils.to_int(get_env_str('IMAGE_MAX_BYTES', tostring(5 * 1024 * 1024), file_env), 'IMAGE_MAX_BYTES', 5 * 1024 * 1024, 1),
    max_reply_chars = utils.to_int(get_env_str('MAX_REPLY_CHARS', '1800', file_env), 'MAX_REPLY_CHARS', 1800, 100),
    temperature = utils.to_float(get_env_str('TEMPERATURE', '0.7', file_env), 'TEMPERATURE', 0.7),
    max_history = utils.to_int(get_env_str('MAX_HISTORY', '10', file_env), 'MAX_HISTORY', 10, 1),
    bot_owner_id = utils.to_int(get_env_str('BOT_OWNER_ID', '0', file_env), 'BOT_OWNER_ID', 0, 0),
  }

  if settings.provider == 'gemini' and not settings.gemini_api_key then
    error('Missing GEMINI_API_KEY for LLM_PROVIDER=gemini')
  end
  if settings.provider == 'groq' and not settings.groq_api_key then
    error('Missing GROQ_API_KEY for LLM_PROVIDER=groq')
  end
  if settings.provider == 'openai' and not settings.openai_api_key then
    error('Missing OPENAI_API_KEY for LLM_PROVIDER=openai')
  end
  if not settings.approval_gemini_api_key then
    error('Missing approval Gemini API key')
  end

  if settings.rpc_activity_type == 'streaming' and settings.rpc_activity_url == '' then
    error('RPC_ACTIVITY_URL is required when RPC_ACTIVITY_TYPE=streaming')
  end

  return settings
end

return M
