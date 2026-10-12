-- Record a token a waiter moved into the claimed list as held. Returns false without recording
-- anything if the claim was already pruned as stale and its token restored to the pool.
local claimed_key     = KEYS[3]
local held_key        = KEYS[2]
local now_ms          = tonumber(ARGV[1])
local lock_timeout_ms = tonumber(ARGV[2])
local acquisition_id  = ARGV[3]
local ttl             = tonumber(ARGV[4])
local token           = ARGV[5]

if redis.call('LREM', claimed_key, 1, token) == 0 then
  return false
end

redis.call('ZADD', held_key, now_ms + lock_timeout_ms, acquisition_id)

for _, key in ipairs(KEYS) do
  redis.call('EXPIRE', key, ttl)
end

return 1
