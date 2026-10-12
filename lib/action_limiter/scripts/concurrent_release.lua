-- Release a held lock and return its token to the pool. Only returns the token if the lock
-- was still held (prevents duplicates when a lock was already reclaimed due to timeout), and
-- only while the pool is under the limit, so a surplus token minted under clock skew is
-- retired rather than recirculated. Pending is excluded from the check: in-flight tokens are
-- in neither the list nor the held set, so skipping the push never loses a token.
local tokens_key     = KEYS[1]
local held_key       = KEYS[2]
local acquisition_id = ARGV[1]
local ttl            = tonumber(ARGV[2])
local limit          = tonumber(ARGV[3])

local removed = redis.call('ZREM', held_key, acquisition_id)
if removed > 0 and (redis.call('LLEN', tokens_key) + redis.call('ZCARD', held_key)) < limit then
  redis.call('RPUSH', tokens_key, '1')
end

for _, key in ipairs(KEYS) do
  redis.call('EXPIRE', key, ttl)
end

return removed
