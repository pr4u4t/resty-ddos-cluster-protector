local redis = require "resty.redis"

---------------------[[ register time series module ]]--------------------------
redis.register_module_prefix("ts")

------------------[[ default rate measure settings table ]]---------------------
local _rate_measure_default_settings = {
    _host                   = "127.0.0.1",          -- redis database address
    _port                   = 6379,                 -- redis database port
    _timeouts               = { 1000, 1000, 1000 }, -- connection, read, write timeout
    _instance_capacity      = 1,                    -- instance capacity
    _retention              = 10000,                 -- keep data for 10s
    _key_prefix             = "req:",               -- timeseries prefix
    _duration               = 5000                  -- duration of aggregation functions
    _debug                  = true
}

---------------------[[ rate measure ]]-----------------------------------------

--[[
    Perform rate measure using given IP, this function returns 
    redis pipeline result.
]]
local function _rate_measure_measure(self,ipaddr)
    local start = self._debug and ngx.time()
    
    if ipaddr == nil then
        ipaddr = ngx.var.remote_addr
    end
    
    self._redis:init_pipeline(1)
    self._redis:ts():create(self._key_prefix..ipaddr..":sum",'LABELS', 'label', 'reqvtime' )
    self._redis:ts():add(self._key_prefix..ipaddr..":live", ngx.time(), 1, 'RETENTION',self._retention,'ENCODING', 'UNCOMPRESSED',
                            'CHUNK_SIZE', 4096, 'DUPLICATE_POLICY', 'SUM', 'LABELS', 'label', 'requests')
    self._redis.ts():createrule(self._key_prefix..ipaddr..":live",self._key_prefix..ipaddr..":sum", 'AGGREGATION', 'SUM', self._duration)
    
    local results, err = self._redis:commit_pipeline()
    
    if results == nil and err ~= nill then
        return nil, err
    end
    
    if self._debug then
        ngx.log(ngx.ERR,"redis measure took: ",ngx.time()-start.." client IP: "..ipaddr)
    end
    
    return results
end

--[[
    create new instance of rate measure object and connect to redis 
    database.
]]
local function _rate_measure_new(settings)
    --set dictionary to default settings
    local dict = _rate_measure_default_settings
    
    --copy settings to dictionary
    if settings ~= nil and type(settings) == "table" then
        for k,v in settings do
            if(v ~= nil) then
                dict[k] = v
            end
        end
    end
    
    dict._redis = redis:new()

    -- set redis connection object timeouts
    dict._redis:set_timeouts(dict._timeouts[1], dict._timeouts[2], dict._timeouts[3])

    -- connect to redis database
    local ok, err = dict._redis:connect(dict._host, dict._port)
    
    if not ok then
        return false, "failed to connect: "..err
    end
    
    return setmetatable(dict, { 
        __index     = { measure = _rate_measure_measure }
    })
end

-- return newly created module 
return setmetatable({},{ 
        __index     = { new = _rate_measure_new },
        __tostring = function() return "resty-conntrack" end
    })
