local key       = KEYS[1]
local now       = tonumber(ARGV[1])
local duration  = tonumber(ARGV[2])
local limit     = tonumber(ARGV[3])
local member    = ARGV[4]

-- Prune entries that have fallen outside the sliding window
redis.call('ZREMRANGEBYSCORE', key, '-inf', now - duration)

-- Check how many operations remain in the current window
local count = redis.call('ZCARD', key)

if count < limit then
  redis.call('ZADD', key, now, member)
  redis.call('PEXPIRE', key, duration + 1000)
  return 1
end

-- Over limit — return negative ms until the oldest entry ages out
local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
if #oldest >= 2 then
  local retry_after = tonumber(oldest[2]) + duration - now
  if retry_after > 0 then return -retry_after end
end

return -1
