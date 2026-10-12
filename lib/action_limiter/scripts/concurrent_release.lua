-- Release a held lock and return its token to the pool. Only returns the token if the lock
-- was still held (prevents duplicates when a lock was already reclaimed due to timeout).
local tokens_key     = KEYS[1]
local held_key       = KEYS[2]
local acquisition_id = ARGV[1]
local ttl            = tonumber(ARGV[2])

local removed = redis.call('ZREM', held_key, acquisition_id)
if removed > 0 then
  redis.call('RPUSH', tokens_key, '1')
end

for _, key in ipairs(KEYS) do
  redis.call('EXPIRE', key, ttl)
end

return removed
