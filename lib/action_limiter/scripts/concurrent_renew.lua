-- Extend a held lock's expiry. Returns false if the lock is no longer held.
local held_key        = KEYS[2]
local now_ms          = tonumber(ARGV[1])
local lock_timeout_ms = tonumber(ARGV[2])
local acquisition_id  = ARGV[3]
local ttl             = tonumber(ARGV[4])

if redis.call('ZSCORE', held_key, acquisition_id) == false then
  return false
end

redis.call('ZADD', held_key, 'XX', now_ms + lock_timeout_ms, acquisition_id)

for _, key in ipairs(KEYS) do
  redis.call('EXPIRE', key, ttl)
end

return acquisition_id
