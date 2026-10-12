-- Try to acquire a token, reclaiming expired locks only when the pool is empty. Returns 1 on
-- success, or the negative ms until a held lock expires or a claim goes stale, whichever is
-- sooner, so a waiter knows when to retry even if no token is released.
local tokens_key      = KEYS[1]
local held_key        = KEYS[2]
local claimed_key     = KEYS[3]
local now_ms          = tonumber(ARGV[1])
local lock_timeout_ms = tonumber(ARGV[2])
local acquisition_id  = ARGV[3]
local ttl             = tonumber(ARGV[4])
local limit           = tonumber(ARGV[5])
local claim_grace_ms  = tonumber(ARGV[6])

local function refresh_ttls()
  for _, key in ipairs(KEYS) do
    redis.call('EXPIRE', key, ttl)
  end
end

local function take_token()
  if not redis.call('LPOP', tokens_key) then return false end

  redis.call('ZADD', held_key, now_ms + lock_timeout_ms, acquisition_id)
  refresh_ttls()
  return true
end

-- Tokens are valued by the time they were pushed. A claim older than the grace period belongs
-- to a waiter that crashed between BLMOVE and recording its hold.
local retry_after = lock_timeout_ms
for _, claim in ipairs(redis.call('LRANGE', claimed_key, 0, -1)) do
  local stale_in = (tonumber(claim) or 0) + claim_grace_ms - now_ms
  if stale_in < 0 then
    redis.call('LREM', claimed_key, 1, claim)
  else
    retry_after = math.min(retry_after, stale_in)
  end
end

-- Every token is in exactly one of the pool, the held set, or the claimed list, so restoring
-- lost tokens and trimming surplus ones (e.g. after the limit was lowered) is exact.
local total = redis.call('LLEN', tokens_key) + redis.call('ZCARD', held_key) + redis.call('LLEN', claimed_key)
for i = total + 1, limit do
  redis.call('RPUSH', tokens_key, ARGV[1])
end
for i = limit + 1, total do
  if not redis.call('LPOP', tokens_key) then break end
end

-- Fast path: try to acquire a token immediately
if take_token() then return 1 end

-- Slow path: reclaim expired locks, then retry
local expired = redis.call('ZRANGEBYSCORE', held_key, '-inf', now_ms)
for _, expired_id in ipairs(expired) do
  redis.call('ZREM', held_key, expired_id)
  redis.call('RPUSH', tokens_key, ARGV[1])
end

if take_token() then return 1 end

local soonest = redis.call('ZRANGE', held_key, 0, 0, 'WITHSCORES')
if soonest[2] then
  retry_after = math.min(retry_after, tonumber(soonest[2]) - now_ms)
end

return -math.max(1, retry_after)
