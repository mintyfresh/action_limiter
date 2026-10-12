-- Try to acquire a token, reclaiming expired locks only when the pool is empty. Returns the
-- acquisition ID on success. On failure, registers the caller as a pending waiter (when it
-- still has time to wait) and returns false.
local tokens_key      = KEYS[1]
local held_key        = KEYS[2]
local pending_key     = KEYS[3]
local now_ms          = tonumber(ARGV[1])
local lock_timeout_ms = tonumber(ARGV[2])
local acquisition_id  = ARGV[3]
local ttl             = tonumber(ARGV[4])
local limit           = tonumber(ARGV[5])
local pending_expiry  = tonumber(ARGV[6])

local function refresh_ttls()
  for _, key in ipairs(KEYS) do
    redis.call('EXPIRE', key, ttl)
  end
end

local function take_token()
  if not redis.call('LPOP', tokens_key) then return false end

  redis.call('ZREM', pending_key, acquisition_id)
  redis.call('ZADD', held_key, now_ms + lock_timeout_ms, acquisition_id)
  refresh_ttls()
  return true
end

-- Waiters whose pending entry expired either gave up or crashed
redis.call('ZREMRANGEBYSCORE', pending_key, '-inf', now_ms)

-- Trim surplus tokens (a lowered limit, or a token minted for a waiter whose pending entry
-- expired mid-flight). Pending is excluded: a token in flight between BRPOP and BRPOP_ACQUIRE
-- is in neither the list nor the held set, so this sum never over-counts and never over-trims.
-- Reclaiming expired holds below moves entries from held to the list, so it needs no re-trim.
local surplus = redis.call('LLEN', tokens_key) + redis.call('ZCARD', held_key) - limit
for i = 1, surplus do
  if not redis.call('LPOP', tokens_key) then break end
end

-- Self-healing: restore a token lost to a crash between BRPOP and BRPOP_ACQUIRE. A live
-- waiter between those two steps still has a pending entry, so its in-flight token is
-- counted here and never duplicated.
local available = redis.call('LLEN', tokens_key)
local held      = redis.call('ZCARD', held_key)
local pending   = redis.call('ZCARD', pending_key)
if (available + held + pending) < limit then
  redis.call('RPUSH', tokens_key, '1')
end

-- Fast path: try to acquire a token immediately
if take_token() then return acquisition_id end

-- Slow path: reclaim expired locks, then retry
local expired = redis.call('ZRANGEBYSCORE', held_key, '-inf', now_ms)
for _, expired_id in ipairs(expired) do
  redis.call('ZREM', held_key, expired_id)
  redis.call('RPUSH', tokens_key, '1')
end

if take_token() then return acquisition_id end

-- No token: register as pending before the caller blocks on BRPOP
if pending_expiry > 0 then
  redis.call('ZADD', pending_key, pending_expiry, acquisition_id)
  refresh_ttls()
end

return false
