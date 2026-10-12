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
-- Never move the timestamp backwards, so a lagging client clock cannot credit refill twice
local stored_at = math.max(now_ms, updated_at)
redis.call('HSET', key, 'points', tostring(balance), 'updated_at_ms', stored_at)
-- Expire once fully refilled, counted from the stored timestamp (which may be ahead of this
-- caller's clock), so debt is never forgiven by an early expiry
local refill_ms = math.ceil((capacity - balance) / rate * 1000)
redis.call('PEXPIRE', key, refill_ms + (stored_at - now_ms) + 1000)
