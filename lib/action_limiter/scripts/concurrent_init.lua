-- Initialize the token pool (idempotent — only adds tokens if total < limit). Reclaims
-- expired locks and prunes expired waiters first so stale entries don't inflate the count.
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

local total = redis.call('LLEN', tokens_key) + redis.call('ZCARD', held_key) + redis.call('ZCARD', pending_key)
for i = total + 1, limit do
  redis.call('RPUSH', tokens_key, '1')
end

for _, key in ipairs(KEYS) do
  redis.call('EXPIRE', key, ttl)
end
