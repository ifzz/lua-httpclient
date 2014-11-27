local http = require("socket.http")
local https_ok, https = pcall(require, "ssl.https")
local urlparser = require("socket.url")
local ltn12 = require("ltn12")

local HttpClient = {}
local httpclient = {}

local default_ssl_params = {
  mode = "client",
  protocol = "tlsv1",
  verify = "peer",
  options = "all",
  cafile = "/etc/ssl/certs/ca-certificates.crt"
}

local default_timeout = 60

local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local meta = getmetatable(t)
  local target = {}
  for k, v in pairs(t) do
    if type(v) == "table" then
        target[k] = cloneTable(v)
    else
        target[k] = v
    end
  end
  setmetatable(target, meta)
  return target
end

local function request(url, params, method, args)
  local resp, r = {}, {}
  local query = params or nil
  local method = method or "GET"
  local uri = url or nil
  local http_client = http
  local ssl_params = args.ssl_opts
  local req_t = {}

  if not uri then
    return {nil, err = "missing url"}
  end

  -- Check if https
  if uri:find("^https") then
    if not https_ok then
      return {nil, "https not supported. Please install luasec"}
    end
    for k, v in pairs(ssl_params) do
      req_t[k] = v
    end
    local http_client = https
  end
  
  http_client.TIMEOUT = args.timeout or default_timeout

  if query then
    q = nil
    if type(query) == "string" then
      q = query
    else
      local qopts = {}
      for k, v in pairs(query) do
        table.insert(qopts, urlparser.escape(k).."="..urlparser.escape(v))
      end
      q = table.concat(qopts, "&")
    end
    uri = uri.."?"..q
  end
  req_t = {
    url=uri,
    sink=ltn12.sink.table(resp),
    method=method,
    redirect=true
  }

  req_t.headers = args.headers or {["Accept"] = "*/*"}
  if args.body then req_t.source = args.body end
  local results = {}
  local r = {http_client.request(req_t)}
  if #r == 2 then
    -- the request failed
    return {nil, err = r[2]}
  else
    -- we got a regular result
    results = {
      body = table.concat(resp),
      code = r[2],
      headers = r[3],
      status_line = r[4],
      err = nil
    }
  end
  
  if (results.code >= 400 and results.code <= 599) then
    -- got an error of some kind
    local e = results.body or results.status_line or "no error"
    local r = results
    r.err = e
    return r
  end

  if (results.code == 301 or results.code == 302 or results.code == 307) then
    local loop_control = args.loop_control or {}
    if loop_control[results.headers.location] then
      return {nil, err = "redirect loop on "..results.headers.location}
    end
    loop_control[results.headers.location] = true
    local location = results.headers.location
    return request(location, params, method, {loop_control = loop_control})
  end
  return results
end


local function get_default_opts(t)
  local nt = deep_copy(t)
  if not nt.timeout then nt.timeout = default_timeout end
  if not nt.ssl_opts then nt.ssl_opts = default_ssl_params end
  return nt
end

local function merge_defaults(t1, defaults)
  for k, v in pairs(defaults) do
    if not t1[k] then t1[k] = v end
  end
  return t1
end

function httpclient.new(opts)
  local self = {}
  self.defaults = (get_default_opts(opts or {}))
  setmetatable(self, { __index = HttpClient })
  return self
end

function HttpClient:set_default(param, value)
  local t = {}
  t[param] = value
  self.defaults = merge_defaults(t, self.defaults)
end

function HttpClient:get_defaults()
  return self.defaults
end

function HttpClient:get(url, options)
  local opts = options or self.defaults
  local params = opts.params or nil
  local method = "GET"

  return request(url, params, method, opts)
end

function HttpClient:post(url, data, options)
  local opts = options or {}
  opts = merge_defaults(opts, self.defaults)
  local params = opts.params or nil
  if opts.content_type then
    opts.headers = opts.headers or {}
    opts.headers["Content-Type"] = opts.content_type
  end
  -- post/put/patch all look similar
  -- allow method passed in via opts to unify "posting" code
  local method = opts.method or "POST"
  if not data then
    return {nil, err = "missing data"}
  else
    opts.body = ltn12.source.string(data)
    opts.headers = opts.headers or {}
    opts.headers["Content-Length"] = string.len(data)
  end

  return request(url, params, method, opts)
end

function HttpClient:put(url, data, options)
    local opts = options or {}
    opts.method = "PUT"
    return self:post(url, data, opts)
end

function HttpClient:patch(url, data, options)
    local opts = options or {}
    opts.method = "PATCH"
    return self:post(url, data, opts)
end

function HttpClient:head(url, options)
  local opts = options or {}
  opts = merge_defaults(opts, self.defaults)
  local params = opts.params or nil

  local method = "HEAD"
  return request(url, params, method, opts)
end

function HttpClient:delete(url, options)
  local opts = options or {}
  opts = merge_defaults(opts, self.defaults)
  local params = opts.params or nil

  local method = "DELETE"
  return request(url, params, method, opts)
end

return httpclient