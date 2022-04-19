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

local reset = 0

--------[[   Private Module Methods   ]]--------

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

--[[
    Set key expirtaion value in ms for redis database entry
    
    arguments:
    config      redis database configration
    key         key in redis database 
    interval    key time to live in ms
    
    return: true, expire time or false, error string
]]
local function _ratelimit_expire_key(config, key)
    local expire, error = config._connection:expire(key, config.interval)
    if not expire then
        return false, "Failed to get ttl: "..error
    end
    
    return true, expire
end

--[[
    Increment rate limit in redis database
    
    arguments:
    config          redis database configration
    rate_key        key on which rate limit should occur
    current_time    current timestamp
    
    return: array of ratelimit info or nil, error string
]]
local function _ratelimit_inc_request(config, rate_key, current_time)
    local key = config.redis.key_prefix .. rate_key
    
    local count, error = config.connection:incr(key)
    if not count then
        return nil, "Failed to incr counter: "..error
    end

    if tonumber(count) == 1 then
        reset = (current_time + config.interval)
        _ratelimit_expire_key(config.connection, key)
    else
        local ttl, error = config.connection:pttl(key)
        if not ttl then
            return nil, "Failed to get ttl: "..error
        end
        if ttl == -1 then
            ttl = config.interval
            _ratelimit_expire_key(config.connection, key)
        end
        reset = (current_time + (ttl * 0.001)) -- convert ms to seconds and add to current time
    end

    local ok, error = config.connection:set_keepalive(config.redis.keepalive, config.redis.pool_size)
    if not ok then
        return nil,"Failed to set keepalive: ", error)
    end

    return {    
        count       = count, 
        remaining   = rate - count, 
        reset       = reset 
    }
end

--------[[   Public Module Methods   ]]--------

--[[ 
    Method that is executed when ratelimit is exceeded
    
    arguments:
    response    
    
    return: true
]]
local function _ratelimit_deny(response)
    ngx_header["Content-Type"] = "application/json; charset=utf-8"
    ngx_header["Retry-After"] = retry_after
    ngx.status = 429
    ngx_say('{"status":429,"status_message":"Your request count (' .. response.count .. ') is over the allowed limit of ' .. rate .. '."}')
    return true
end

--[[ 
    Method that is executed when ratelimit is not exceeded
    
    arguments:
    response    
    
    return: true
]]

local function _ratelimit_allow(response)
    ngx_header["X-RateLimit-Limit"] = response.rate
    ngx_header["X-RateLimit-Remaining"] = floor(response.remaining)
    ngx_header["X-RateLimit-Reset"] = floor(response.reset)
    return true
end

local function _ratelimit_limit(config,key)
    local error
    
    config.log_level = config.log_level or ratelimit_default_settings._log_level
    config.rate = config.rate or ratelimit_default_settings._rate
    config.interval = config.interval or ratelimit_default_settings._interval

    if not config.connection then
        config.connection, error = _ratelimit_redis_connection(config)
        if not config.connection and error ~= nil then
            ngx_log(config.log_level,error)
            return false, error
        end
    end

    local current_time = ngx_now()
    local connection = config.connection
    
    local key = key or ngx.var.remote_addr
    local interval = config.interval or ratelimit_default_settings._interval

    local response, error = _ratelimit_inc_request(connection, key, current_time)
    if not response then
        ngx_log(log_level,error)
        return false, error
    end

    response.rate = config.rate or ratelimit_default_settings._rate
    
    if response.count > config.rate then
        response.retry_after = floor(response.reset - current_time)
        if response.retry_after < 0 then
            response.retry_after = 0
        end

        return self.deny(response)
    else
        return self.allow(response)
    end
end

return setmetatable({},{ __index = {
        limit = _ratelimit_limit,
        allow = _ratelimit_allow,
        deny  = _ratelimit_deny
    }})
