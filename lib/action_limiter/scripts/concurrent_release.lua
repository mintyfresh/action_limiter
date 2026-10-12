-- Release a held lock and return its token to the pool. Only returns the token if the lock
-- was still held (prevents duplicates when a lock was already reclaimed due to timeout), and
-- only while the pool is under the limit, so a surplus token is retired rather than
-- recirculated.
local tokens_key     = KEYS[1]
local held_key       = KEYS[2]
local claimed_key    = KEYS[3]
local acquisition_id = ARGV[1]
local ttl            = tonumber(ARGV[2])
local limit          = tonumber(ARGV[3])

local removed = redis.call('ZREM', held_key, acquisition_id)
local total = redis.call('LLEN', tokens_key) + redis.call('ZCARD', held_key) + redis.call('LLEN', claimed_key)
if removed > 0 and total < limit then
  redis.call('RPUSH', tokens_key, ARGV[4])
end

for _, key in ipairs(KEYS) do
  redis.call('EXPIRE', key, ttl)
end

return removed
