local now_ms     = tonumber(ARGV[1])
local interval   = tonumber(ARGV[2])
local limit      = tonumber(ARGV[3])
local bucket_end = tonumber(ARGV[4])

-- Phase 1: Check every bucket before touching any
for i = 1, #KEYS do
  if (tonumber(redis.call('GET', KEYS[i])) or 0) >= limit then
    -- Over limit — return negative ms until the next bucket begins
    local retry_after = bucket_end - now_ms
    if retry_after <= 0 then retry_after = 1 end
    return -retry_after
  end
end

-- Phase 2: All buckets are under limit — record the operation on each
for i = 1, #KEYS do
  if redis.call('INCR', KEYS[i]) == 1 then
    redis.call('PEXPIRE', KEYS[i], interval * 2)
  end
end

return 1
