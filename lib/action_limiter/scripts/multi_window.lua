local num_keys = #KEYS
local now      = tonumber(ARGV[1])
local duration = tonumber(ARGV[2])
local limit    = tonumber(ARGV[3])
local member   = ARGV[4]

-- Phase 1: Prune expired entries and check all keys
local max_retry_after = -1

for i = 1, num_keys do
  redis.call('ZREMRANGEBYSCORE', KEYS[i], '-inf', now - duration)

  if redis.call('ZCARD', KEYS[i]) >= limit then
    local oldest = redis.call('ZRANGE', KEYS[i], 0, 0, 'WITHSCORES')
    if #oldest >= 2 then
      local retry_after = tonumber(oldest[2]) + duration - now
      if retry_after > max_retry_after then
        max_retry_after = retry_after
      end
    end
  end
end

if max_retry_after >= 0 then
  if max_retry_after > 0 then return -max_retry_after end
  return -1
end

-- Phase 2: All keys are under limit — record the operation on each
for i = 1, num_keys do
  redis.call('ZADD', KEYS[i], now, member)
  redis.call('PEXPIRE', KEYS[i], duration + 1000)
end

return 1
