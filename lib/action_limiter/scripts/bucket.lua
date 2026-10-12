local bucket_key = KEYS[1]
local now_ms     = tonumber(ARGV[1])
local interval   = tonumber(ARGV[2])
local limit      = tonumber(ARGV[3])
local bucket_end = tonumber(ARGV[4])

-- Increment immediately. Saves a GET operation.
local count = redis.call('INCR', bucket_key)

if count == 1 then
  redis.call('PEXPIRE', bucket_key, interval * 2)
end

if count > limit then
  -- Over limit — return negative ms until the next bucket begins
  local retry_after = bucket_end - now_ms
  if retry_after <= 0 then retry_after = 1 end
  return -retry_after
end

return 1
