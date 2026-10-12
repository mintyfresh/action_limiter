-- Initialize the token pool (idempotent). Reclaims expired locks and prunes expired waiters
-- first so stale entries don't inflate the count, trims surplus tokens (e.g. after the limit
-- was lowered), then adds tokens if total < limit.
local tokens_key  = KEYS[1]
local held_key    = KEYS[2]
local pending_key = KEYS[3]
local limit       = tonumber(ARGV[1])
local now_ms      = tonumber(ARGV[2])
local ttl         = tonumber(ARGV[3])

local expired = redis.call('ZRANGEBYSCORE', held_key, '-inf', now_ms)
for _, expired_id in ipairs(expired) do
  redis.call('ZREM', held_key, expired_id)
  redis.call('RPUSH', tokens_key, '1')
end
redis.call('ZREMRANGEBYSCORE', pending_key, '-inf', now_ms)

-- Trim the surplus. Pending is excluded: a token in flight between BRPOP and BRPOP_ACQUIRE is
-- in neither the list nor the held set, so this sum never over-counts and never over-trims.
local surplus = redis.call('LLEN', tokens_key) + redis.call('ZCARD', held_key) - limit
for i = 1, surplus do
  if not redis.call('LPOP', tokens_key) then break end
end

local total = redis.call('LLEN', tokens_key) + redis.call('ZCARD', held_key) + redis.call('ZCARD', pending_key)
for i = total + 1, limit do
  redis.call('RPUSH', tokens_key, '1')
end

for _, key in ipairs(KEYS) do
  redis.call('EXPIRE', key, ttl)
end
