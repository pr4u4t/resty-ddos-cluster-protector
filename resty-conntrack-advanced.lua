--------[[ Private Module Dependencies ]]-------
local ok, redis = pcall(require, "resty.redis")             -- safely check if the redis module is available
if not ok then
    return false, "Failed to require redis database driver" -- if not return and do not initialize module
end

--------[[   MT cache to speed up   ]]----------

-- nginx cache
local ngx_header = ngx.header 
local ngx_say    = ngx.say
local ngx_exit   = ngx.exit
local ngx_err    = ngx.ERR
local ngx_log    = ngx.log
local ngx_now    = ngx.now
local HTTP_OK    = ngx.HTTP_OK

-- others cache
local floor      = math.floor
local type       = type
local assert     = assert
local tonumber   = tonumber

--------[[ Private Module Variables ]]----------

local ratelimit_default_settings = {
    -- default redis database settings
    _host                   = "127.0.0.1",          -- redis database address
    _port                   = 6379,                 -- redis database port
    _timeouts               = { 1000, 1000, 1000 }, -- connection, read, write timeout in [ms]
    _key_prefix             = "RL:",                -- key prefix
    _keepalive              = 10000                 -- how long to keep connection in pool for reuse
    _pool_size              = 100                   -- connection pool size
    
    -- default limit settings
    _log_level              = ngx_err,              -- default log level
    _rate                   = 10,                   -- request rate limit in given interval 
    _interval               = 1                     -- time interval in which rate limit is counted
}

local _M = {
    BUSY = 2,
    FORBIDDEN = 3
}

local function is_str(s)
    return type(s) == "string" 
end

local function is_num(n) 
    return type(n) == "number" 
end

local redis_limit_req_script_sha
local redis_limit_req_script = [==[
local key = KEYS[1]
local rate, burst = tonumber(ARGV[1]), tonumber(ARGV[2])
local now, duration = tonumber(ARGV[3]), tonumber(ARGV[4])

local excess, last, forbidden = 0, 0, 0

local res = redis.pcall('GET', key)
if type(res) == "table" and res.err then
    return {err=res.err}
end

if res and type(res) == "string" then
    local v = cjson.decode(res)
    if v and #v > 2 then
        excess, last, forbidden = v[1], v[2], v[3]
    end

    if forbidden == 1 then
        return {3, excess} -- FORBIDDEN
    end

    local ms = math.abs(now - last)
    excess = excess - rate * ms / 1000 + 1000

    if excess < 0 then
        excess = 0
    end

    if excess > burst then
        if duration > 0 then
            local res = redis.pcall('SET', key,
                                    cjson.encode({excess, now, 1}))
            if type(res) == "table" and res.err then
                return {err=res.err}
            end

            local res = redis.pcall('EXPIRE', key, duration)
            if type(res) == "table" and res.err then
                return {err=res.err}
            end
        end

        return {2, excess} -- BUSY
    end
end

local res = redis.pcall('SET', key, cjson.encode({excess, now, 0}))
if type(res) == "table" and res.err then
    return {err=res.err}
end

local res = redis.pcall('EXPIRE', key, 60)
if type(res) == "table" and res.err then
    return {err=res.err}
end

return {1, excess}
]==]


local function redis_create(host, port, timeout, pass, dbid) -- connection function, returns connection
end

--[[ 
    This method perform connection to redis database
    
    arguments:
    config      redis database configration
    
    return: redis_connection table or nil, error string on fail
    
]]
local function _ratelimit_redis_connection(config)
    -- get redis database connection configuration
    local redis_config = config.redis_config or {}

    redis_config.host = redis_config.host or ratelimit_default_settings._host
    redis_config.port = redis_config.port or ratelimit_default_settings._port
    redis_config.timeouts = redis_config.timeouts or ratelimit_default_settings._timeouts
    redis_config.key_prefix = redis_config.key_prefix or ratelimit_default_settings._key_prefix
    redis_config.keepalive = redis_config.keepalive or ratelimit_default_settings._keepalive
    redis_config.pool_size = redis_config.pool_size or ratelimit_default_settings._pool_size
    
    
    -- instantiate new redis database connection
    local redis_connection = redis:new()
    -- set redis database timeouts
    redis_connection:set_timeout(unpack(redis_config.timeouts))

    -- try to connect to redis database
    local ok, error = redis_connection:connect(redis_config.host, redis_config.port)
    if not ok then
        return nil, "Failed to connect to redis: "..error
    end

    if redis_config._password then
        if redis_config._username then
            local ok, error = redis_connection:auth(redis_config.username, redis_config.password)
            if not ok then
                return nil, "Failed to authenticate to redis database"..error
            end
        else
            local ok, error = redis_connection:auth(self.password)
            if not ok then
                return nil, "Failed to authenticate to redis database"..error
            end
        end
    end
    
    config.redis = redis_config
    config._connection = redis_connection
    
    return redis_connection
end

local function redis_commit(red, zone, key, rate, burst, duration)
    if not redis_limit_req_script_sha then
        local res, err = red:script("LOAD", redis_limit_req_script)
        if not res then
            return nil, err
        end

        redis_limit_req_script_sha = res
    end

    local now = ngx.now() * 1000
    local res, err = red:evalsha(redis_limit_req_script_sha, 1,
                                 zone .. ":" .. key, rate, burst, now,
                                 duration)
    if not res then
        redis_limit_req_script_sha = nil
        return nil, err
    end

    -- put it into the connection pool of size 100,
    -- with 10 seconds max idle timeout
    local ok, err = red:set_keepalive(10000, 100)
    if not ok then
        ngx.log(ngx.WARN, "failed to set keepalive: ", err)
    end

    return res
end


-- local lim, err = class.new(zone, rate, burst, duration)
function _M.new(zone, rate, burst, duration)
    local zone = zone or "ratelimit"
    local rate = rate or "1r/s"
    local burst = burst or 0
    local duration = duration or 0

    local scale = 1
    local len = #rate

    if len > 3 and rate:sub(len - 2) == "r/s" then
        scale = 1
        rate = rate:sub(1, len - 3)
    elseif len > 3 and rate:sub(len - 2) == "r/m" then
        scale = 60
        rate = rate:sub(1, len - 3)
    end

    rate = tonumber(rate)

    assert(rate > 0 and burst >= 0 and duration >= 0)

    burst = burst * 1000
    rate = floor(rate * 1000 / scale)

    return setmetatable({
            zone = zone,
            rate = rate,
            burst = burst,
            duration = duration,
    }, mt)
end

-- local delay, err = lim:incoming(key, redis)
function _M.incoming(self, key, redis)
    if type(redis) ~= "table" then
        redis = {}
    end

    if not pcall(redis.get_reused_times, redis) then
        local cfg = redis
        local red, err = redis_create(cfg.host, cfg.port, cfg.timeout,
                                      cfg.pass, cfg.dbid)
        if not red then
            return nil, err
        end

        redis = red
    end

    local res, err = redis_commit(
        redis, self.zone, key, self.rate, self.burst, self.duration)
    if not res then
        return nil, err
    end

    local state, excess = res[1], res[2]
    if state == _M.BUSY or state == _M.FORBIDDEN then
        return nil, "rejected"
    end

    -- state = _M.OK
    return excess / self.rate, excess / 1000
end

return setmetatable(,)
