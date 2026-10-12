-- Record a BRPOP-acquired token: move the waiter from pending to held and refresh TTLs.
local pending_key     = KEYS[3]
local held_key        = KEYS[2]
local now_ms          = tonumber(ARGV[1])
local lock_timeout_ms = tonumber(ARGV[2])
local acquisition_id  = ARGV[3]
local ttl             = tonumber(ARGV[4])

redis.call('ZREM', pending_key, acquisition_id)
redis.call('ZADD', held_key, now_ms + lock_timeout_ms, acquisition_id)

for _, key in ipairs(KEYS) do
  redis.call('EXPIRE', key, ttl)
end
