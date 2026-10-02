-- SPDX-License-Identifier: MPL-2.0
-- json.lua — the small JSON the mixer needs: encode an op, decode a reply.
-- Integers are written as integers (Control.hs reads slot with asInt), keys in
-- sorted order (stable wire bytes for tests). Copyright (c) 2026 DeMoD LLC.
local J = {}

local esc = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
      return false
    end
    n = n + 1
  end
  return n == #t
end

function J.encode(v)
  local t = type(v)
  if v == nil or v == J.null then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      error("json: non-finite number")
    end
    if math.type(v) == "integer" then
      return string.format("%d", v)
    end
    return string.format("%.6g", v)
  elseif t == "string" then
    return '"'
      .. v:gsub('[%c"\\]', function(c)
        return esc[c] or string.format("\\u%04x", c:byte())
      end)
      .. '"'
  elseif t == "table" then
    local out = {}
    if next(v) ~= nil and is_array(v) then
      for i = 1, #v do
        out[i] = J.encode(v[i])
      end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
      keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    for i, k in ipairs(keys) do
      out[i] = J.encode(k) .. ":" .. J.encode(v[k])
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("json: cannot encode " .. t)
end

J.null = setmetatable({}, {
  __tostring = function()
    return "null"
  end,
})

-- decode(s) -> value, or nil + error. JSON null decodes to J.null.
function J.decode(s)
  local i = 1
  local function ws()
    i = s:find("[^ \t\r\n]", i) or (#s + 1)
  end
  local value
  local function str()
    local out, j = {}, i + 1
    while true do
      local c = s:sub(j, j)
      if c == "" then
        error("unterminated string")
      end
      if c == '"' then
        i = j + 1
        return table.concat(out)
      end
      if c == "\\" then
        local e = s:sub(j + 1, j + 1)
        local map = {
          b = "\b",
          f = "\f",
          n = "\n",
          r = "\r",
          t = "\t",
          ['"'] = '"',
          ["\\"] = "\\",
          ["/"] = "/",
        }
        if e == "u" then
          local cp = tonumber(s:sub(j + 2, j + 5), 16) or error("bad \\u escape")
          out[#out + 1] = utf8.char(cp)
          j = j + 6
        else
          out[#out + 1] = map[e] or error("bad escape")
          j = j + 2
        end
      else
        out[#out + 1] = c
        j = j + 1
      end
    end
  end
  function value()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      i = i + 1
      local t = {}
      ws()
      if s:sub(i, i) == "}" then
        i = i + 1
        return t
      end
      while true do
        ws()
        if s:sub(i, i) ~= '"' then
          error("expected key")
        end
        local k = str()
        ws()
        if s:sub(i, i) ~= ":" then
          error("expected ':'")
        end
        i = i + 1
        t[k] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "}" then
          return t
        elseif d ~= "," then
          error("expected ',' or '}'")
        end
      end
    elseif c == "[" then
      i = i + 1
      local t = {}
      ws()
      if s:sub(i, i) == "]" then
        i = i + 1
        return t
      end
      while true do
        t[#t + 1] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "]" then
          return t
        elseif d ~= "," then
          error("expected ',' or ']'")
        end
      end
    elseif c == '"' then
      return str()
    elseif s:sub(i, i + 3) == "true" then
      i = i + 4
      return true
    elseif s:sub(i, i + 4) == "false" then
      i = i + 5
      return false
    elseif s:sub(i, i + 3) == "null" then
      i = i + 4
      return J.null
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
      if not num or num == "" then
        error("unexpected '" .. c .. "' at " .. i)
      end
      i = i + #num
      return math.tointeger(tonumber(num)) or tonumber(num)
    end
  end
  local ok, v = pcall(function()
    local r = value()
    ws()
    if i <= #s then
      error("trailing data")
    end
    return r
  end)
  if ok then
    return v
  end
  return nil, v
end

return J
