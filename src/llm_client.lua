local http = require('coro-http')
local json = require('json')

local LLMClient = {}
LLMClient.__index = LLMClient

local function encode_json(data)
  return json.encode(data)
end

local function decode_json(payload)
  local ok, parsed = pcall(json.decode, payload)
  if not ok then
    return nil
  end
  return parsed
end

local function request_json(method, url, headers, body_table)
  local payload = body_table and encode_json(body_table) or ''
  local request_headers = headers or {}
  table.insert(request_headers, { 'Content-Type', 'application/json' })

  local response, body = http.request(method, url, request_headers, payload)
  local status = tonumber(response and response.code or 0) or 0
  local body_text = body
  if type(body_text) == 'table' then
    body_text = table.concat(body_text)
  end
  if status < 200 or status >= 300 then
    error('HTTP ' .. tostring(status) .. ': ' .. tostring(body_text))
  end

  local parsed = decode_json(body_text)
  if not parsed then
    error('Invalid JSON response')
  end
  return parsed
end

function LLMClient.new(settings)
  local self = setmetatable({}, LLMClient)
  self.settings = settings
  return self
end

function LLMClient:generate(messages)
  if self.settings.provider == 'gemini' then
    return self:_call_gemini(messages)
  end
  if self.settings.provider == 'groq' then
    return self:_call_groq(messages)
  end
  if self.settings.provider == 'openai' then
    return self:_call_openai(messages)
  end
  error('Unsupported provider: ' .. tostring(self.settings.provider))
end

function LLMClient:approve_call_name(field_name, value)
  local raw = self:_approve_call_name_gemini(field_name, value)
  local normalized = self:_normalize_yes_no(raw)
  return normalized == 'yes'
end

function LLMClient:_call_gemini(messages)
  if not self.settings.gemini_api_key then
    error('Missing GEMINI_API_KEY')
  end
  local model = self.settings.gemini_model
  local url = string.format(
    'https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s',
    model,
    self.settings.gemini_api_key
  )

  local payload = {
    contents = self:_build_gemini_contents(messages),
    generationConfig = {
      temperature = self.settings.temperature,
    },
    systemInstruction = {
      parts = {
        { text = self.settings.system_prompt },
      },
    },
  }

  local data = request_json('POST', url, {}, payload)
  return self:_extract_gemini_text(data, 'Gemini')
end

function LLMClient:_approve_call_name_gemini(field_name, value)
  if not self.settings.approval_gemini_api_key then
    error('Missing approval Gemini API key')
  end
  local model = self.settings.gemini_approval_model
  local url = string.format(
    'https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s',
    model,
    self.settings.approval_gemini_api_key
  )

  local payload = {
    contents = {
      {
        role = 'user',
        parts = {
          { text = string.format('Call-name field: %s\nContent: %s', field_name, value) },
        },
      },
    },
    generationConfig = { temperature = 0 },
    systemInstruction = {
      parts = {
        {
          text = table.concat({
            "You are a moderator for Discord call-names.",
            "Reply with exactly one word: 'yes' or 'no'.",
            "Reply 'no' if content is insulting, harassing, hateful, sexual, discriminatory, or disrespectful.",
          }, ' '),
        },
      },
    },
  }

  local data = request_json('POST', url, {}, payload)
  return self:_extract_gemini_text(data, 'Gemini approval')
end

function LLMClient:_call_groq(messages)
  if not self.settings.groq_api_key then
    error('Missing GROQ_API_KEY')
  end
  local payload = {
    model = self.settings.groq_model,
    messages = self:_build_openai_style_messages(messages),
    temperature = self.settings.temperature,
  }
  local data = request_json('POST', 'https://api.groq.com/openai/v1/chat/completions', {
    { 'Authorization', 'Bearer ' .. self.settings.groq_api_key },
  }, payload)
  return self:_extract_openai_style_text(data, 'Groq')
end

function LLMClient:_call_openai(messages)
  if not self.settings.openai_api_key then
    error('Missing OPENAI_API_KEY')
  end
  local payload = {
    model = self.settings.openai_model,
    messages = self:_build_openai_style_messages(messages),
    temperature = self.settings.temperature,
  }
  local data = request_json('POST', 'https://api.openai.com/v1/chat/completions', {
    { 'Authorization', 'Bearer ' .. self.settings.openai_api_key },
  }, payload)
  return self:_extract_openai_style_text(data, 'OpenAI')
end

function LLMClient:_build_gemini_contents(messages)
  local contents = {}
  for _, msg in ipairs(messages) do
    local role = (msg.role == 'assistant') and 'model' or 'user'
    local parts = {}
    local text = tostring(msg.content or '')
    if text ~= '' then
      table.insert(parts, { text = text })
    end

    local images = msg.images or {}
    for _, image in ipairs(images) do
      if image.data_b64 and image.mime_type then
        table.insert(parts, {
          inlineData = {
            mimeType = image.mime_type,
            data = image.data_b64,
          },
        })
      end
    end

    if #parts > 0 then
      table.insert(contents, {
        role = role,
        parts = parts,
      })
    end
  end
  return contents
end

function LLMClient:_build_openai_style_messages(messages)
  local out = {
    {
      role = 'system',
      content = self.settings.system_prompt,
    },
  }

  for _, msg in ipairs(messages) do
    local images = msg.images or {}
    local text = tostring(msg.content or '')
    if #images > 0 then
      local parts = {}
      if text ~= '' then
        table.insert(parts, { type = 'text', text = text })
      end
      for _, image in ipairs(images) do
        local image_url = image.url
        if not image_url and image.data_b64 and image.mime_type then
          image_url = 'data:' .. image.mime_type .. ';base64,' .. image.data_b64
        end
        if image_url then
          table.insert(parts, {
            type = 'image_url',
            image_url = { url = image_url },
          })
        end
      end
      table.insert(out, {
        role = msg.role,
        content = parts,
      })
    elseif text ~= '' then
      table.insert(out, {
        role = msg.role,
        content = text,
      })
    end
  end

  return out
end

function LLMClient:_extract_gemini_text(data, context)
  if type(data.text) == 'string' and data.text:match('%S') then
    return data.text:match('^%s*(.-)%s*$')
  end

  if type(data.candidates) == 'table' then
    for _, candidate in ipairs(data.candidates) do
      local content = candidate.content
      if type(content) == 'table' and type(content.parts) == 'table' then
        local text_parts = {}
        for _, part in ipairs(content.parts) do
          if type(part.text) == 'string' and part.text:match('%S') then
            table.insert(text_parts, part.text:match('^%s*(.-)%s*$'))
          end
        end
        if #text_parts > 0 then
          return table.concat(text_parts, '\n')
        end
      end
    end
  end

  error(context .. ' returned an empty response')
end

function LLMClient:_extract_openai_style_text(data, context)
  if type(data.choices) ~= 'table' or not data.choices[1] then
    error(context .. ' returned no choices')
  end
  local message = data.choices[1].message or {}
  if type(message.content) == 'string' and message.content:match('%S') then
    return message.content:match('^%s*(.-)%s*$')
  end
  if type(message.content) == 'table' then
    local chunks = {}
    for _, part in ipairs(message.content) do
      if type(part) == 'table' and part.type == 'text' and type(part.text) == 'string' then
        table.insert(chunks, part.text)
      end
    end
    if #chunks > 0 then
      return table.concat(chunks, '\n')
    end
  end
  error(context .. ' returned an empty response')
end

function LLMClient:_normalize_yes_no(value)
  local cleaned = tostring(value):lower():gsub("[`'\".!?%[%]%(%){} ]", '')
  if cleaned == 'yes' or cleaned == 'y' then
    return 'yes'
  end
  if cleaned == 'no' or cleaned == 'n' then
    return 'no'
  end
  return nil
end

function LLMClient:aclose()
end

return LLMClient
