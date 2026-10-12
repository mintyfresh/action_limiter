-- Refill the bucket for elapsed time, then deduct the estimate if enough points are
-- available. Returns 0 on success, or the ms until enough points will have restored.
local key      = KEYS[1]
local now_ms   = tonumber(ARGV[1])
local capacity = tonumber(ARGV[2])
local rate     = tonumber(ARGV[3])
local estimate = tonumber(ARGV[4])

-- A missing key is a full bucket
local state      = redis.call('HMGET', key, 'points', 'updated_at_ms')
local points     = tonumber(state[1]) or capacity
local updated_at = tonumber(state[2]) or now_ms
local elapsed    = math.max(0, now_ms - updated_at)
-- Never move the timestamp backwards, so a lagging client clock cannot credit refill twice
local available  = math.min(capacity, points + elapsed * rate / 1000)

if available < estimate then
  return math.ceil((estimate - available) / rate * 1000)
end

local balance = available - estimate
redis.call('HSET', key, 'points', tostring(balance), 'updated_at_ms', math.max(now_ms, updated_at))
-- Expire once fully refilled, so debt is never forgiven by an early expiry
redis.call('PEXPIRE', key, math.ceil((capacity - balance) / rate * 1000) + 1000)

return 0
