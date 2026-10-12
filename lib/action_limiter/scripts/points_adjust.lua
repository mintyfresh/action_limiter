-- Refill the bucket for elapsed time, then apply a correction: a positive delta refunds an
-- overestimate (capped at capacity), a negative delta debits an underestimate (may go negative).
local key      = KEYS[1]
local now_ms   = tonumber(ARGV[1])
local capacity = tonumber(ARGV[2])
local rate     = tonumber(ARGV[3])
local delta    = tonumber(ARGV[4])

local state      = redis.call('HMGET', key, 'points', 'updated_at_ms')
local points     = tonumber(state[1]) or capacity
local updated_at = tonumber(state[2]) or now_ms
local elapsed    = math.max(0, now_ms - updated_at)
local available  = math.min(capacity, points + elapsed * rate / 1000)

local balance = math.min(capacity, available + delta)
redis.call('HSET', key, 'points', tostring(balance), 'updated_at_ms', now_ms)
redis.call('PEXPIRE', key, math.ceil((capacity - balance) / rate * 1000) + 1000)
