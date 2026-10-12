# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class ConcurrentTest < TestCase
    before do
      @key = T.let("test:limiter:concurrent:#{::SecureRandom.hex(8)}", String)
    end

    after do
      cleanup_keys(tokens_key, held_key, claimed_key)
    end

    sig { returns(String) }
    attr_reader :key

    sig { returns(String) }
    def tokens_key = "{#{key}}:tokens"

    sig { returns(String) }
    def held_key = "{#{key}}:held"

    sig { returns(String) }
    def claimed_key = "{#{key}}:claimed"

    # Simulates another process holding the only token until +expiry_ms+
    sig { params(expiry_ms: Integer).void }
    def occupy_token(expiry_ms: now_ms + 10_000)
      redis.lpop(tokens_key)
      redis.zadd(held_key, expiry_ms, 'other-process')
    end

    # Runs +threads+ x +iterations+ holds of +hold+ seconds each and returns the most holders
    # observed at once
    sig { params(limiter: Concurrent, threads: Integer, iterations: Integer, hold: Float).returns(Integer) }
    def peak_concurrency(limiter, threads:, iterations:, hold:)
      mutex = ::Thread::Mutex.new
      current = 0
      peak = 0

      workers = Array.new(threads) do
        Thread.new do
          iterations.times do
            limiter.within_limit do
              mutex.synchronize { peak = [peak, current += 1].max }
              sleep(hold)
              mutex.synchronize { current -= 1 }
            end
          end
        end
      end
      workers.each(&:join)
      peak
    end

    it 'returns the block result when under the limit' do
      limiter = Concurrent.new(key, limit: 3, lock_timeout: 10)

      assert_equal :result, limiter.within_limit { :result }
    end

    it 'releases the lock after the block completes' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      limiter.within_limit { nil }

      assert_equal :result, limiter.within_limit { :result }
    end

    it 'releases the lock after the block raises' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      assert_raises(RuntimeError) { limiter.within_limit { raise 'boom' } }
      assert_equal :result, limiter.within_limit { :result }
    end

    it 'raises OverLimit when all slots are held' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      occupy_token

      error = assert_raises(OverLimit) { limiter.within_limit { :result } }

      assert_in_delta 10.0, error.retry_after
    end

    it 'reclaims stale locks from crashed processes' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 1)
      occupy_token(expiry_ms: now_ms - 2000)

      assert_equal :result, limiter.within_limit { :result }
    end

    it 'returns all tokens to the pool after sequential operations' do
      limiter = Concurrent.new(key, limit: 3, lock_timeout: 10)
      3.times { limiter.within_limit { nil } }

      assert_equal 3, redis.llen(tokens_key)
    end

    it 'does not touch Redis until the limiter is used' do
      Concurrent.new(key, limit: 3, lock_timeout: 10, redis: ::Redis.new(url: 'redis://localhost:1'))

      assert_equal 0, redis.exists(tokens_key, held_key, claimed_key)
    end

    it 'does not add extra tokens when several instances share a key' do
      Concurrent.new(key, limit: 3, lock_timeout: 10).within_limit { nil }
      Concurrent.new(key, limit: 3, lock_timeout: 10).within_limit { nil }

      assert_equal 3, redis.llen(tokens_key)
    end

    it 'accepts ActiveSupport::Duration arguments' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10.seconds, wait_timeout: 1.second, ttl: 5.seconds)

      assert_equal 10, limiter.lock_timeout
      assert_equal 1, limiter.wait_timeout
      assert_equal :result, limiter.within_limit { :result }
    end

    it 'admits a waiter when a token is released while it is blocked' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10, wait_timeout: 2)
      holder = Thread.new { limiter.within_limit { sleep(0.3) } }
      sleep(0.05)

      assert_equal :result, limiter.within_limit { :result }
      holder.join

      assert_equal 1, redis.llen(tokens_key)
      assert_equal 0, redis.llen(claimed_key)
    end

    it 'leaves no claim behind when the wait times out' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10, wait_timeout: 1)
      occupy_token

      assert_raises(OverLimit) { limiter.within_limit { nil } }
      assert_equal 0, redis.llen(claimed_key)
    end

    it 'does not block other threads sharing the connection pool while waiting' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10, wait_timeout: 1)
      occupy_token
      waiter = Thread.new do
        limiter.within_limit { nil }
      rescue OverLimit
        nil
      end
      sleep(0.1)

      started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      ActionLimiter.redis.with(&:ping)

      assert_operator ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at, :<, 0.2
      waiter.join
    end

    it 'waits on a pooled connection instead of opening a new one' do
      pool = ::ConnectionPool.new(size: 1) { ::Redis.new(url: REDIS_URL) }
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10, wait_timeout: 1, redis: pool)
      occupy_token
      assert_raises(OverLimit) { limiter.within_limit { nil } }
      connections = -> { redis.info('stats').fetch('total_connections_received').to_i }
      before = connections.call

      assert_raises(OverLimit) { limiter.within_limit { nil } }
      assert_equal before, connections.call
    end

    it 'raises OverLimit once wait_timeout elapses instead of blocking indefinitely' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10, wait_timeout: 1)
      occupy_token

      started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      assert_raises(OverLimit) { limiter.within_limit { nil } }
      assert_operator ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at, :<, 1.5
    end

    it 'self-heals a token lost with no waiter in flight' do
      limiter = Concurrent.new(key, limit: 2, lock_timeout: 10)
      redis.lpop(tokens_key)

      assert_equal :healed, limiter.within_limit { :healed }
    end

    it 'does not mint a token while a live claim holds one' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      redis.lpop(tokens_key)
      redis.rpush(claimed_key, now_ms.to_s)

      assert_raises(OverLimit) { limiter.within_limit { :admitted } }
      assert_equal 0, redis.llen(tokens_key)
    end

    it 'restores the token of a stale claim' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      redis.lpop(tokens_key)
      redis.rpush(claimed_key, (now_ms - Concurrent::CLAIM_GRACE_MS - 1).to_s)

      assert_equal :healed, limiter.within_limit { :healed }
      assert_equal 0, redis.llen(claimed_key)
    end

    it 'restores a lost token while another caller is waiting' do
      limiter = Concurrent.new(key, limit: 2, lock_timeout: 30, wait_timeout: 5)
      occupy_token(expiry_ms: now_ms + 30_000)
      redis.lpop(tokens_key)
      redis.rpush(claimed_key, (now_ms - Concurrent::CLAIM_GRACE_MS + 500).to_s)
      started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      assert_equal :healed, limiter.within_limit { :healed }
      assert_operator ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at, :<, 1.5
    end

    it 'admits a waiter once an abandoned lock expires instead of waiting out wait_timeout' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10, wait_timeout: 5)
      occupy_token(expiry_ms: now_ms + 500)
      started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      assert_equal :result, limiter.within_limit { :result }
      assert_operator ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at, :<, 1.5
    end

    it 'trims surplus tokens when the limit is lowered' do
      Concurrent.new(key, limit: 5, lock_timeout: 10).within_limit { nil }
      limiter = Concurrent.new(key, limit: 2, lock_timeout: 10, wait_timeout: 5)
      limiter.within_limit { nil }

      assert_equal 2, redis.llen(tokens_key)

      assert_operator peak_concurrency(limiter, threads: 5, iterations: 1, hold: 0.1), :<=, 2
    end

    it 'trims a surplus token found in the pool on acquire' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      redis.rpush(tokens_key, '1')

      limiter.within_limit { nil }

      assert_equal 1, redis.llen(tokens_key)
    end

    it 'never exceeds the limit under contention and settles back to the limit' do
      limiter = Concurrent.new(key, limit: 3, lock_timeout: 10, wait_timeout: 5)

      assert_operator peak_concurrency(limiter, threads: 20, iterations: 5, hold: 0.01), :<=, 3
      assert_equal 3, redis.llen(tokens_key)
      assert_equal 0, redis.llen(claimed_key)
    end

    it 'instruments acquire and over_limit' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      acquired = capture_events('acquire.action_limiter') { limiter.within_limit { nil } }
      occupy_token
      over = capture_events('over_limit.action_limiter') do
        assert_raises(OverLimit) { limiter.within_limit { nil } }
      end

      assert_equal 1, acquired.size
      assert_equal 1, over.size
    end

    it 'validates its arguments' do
      assert_raises(ArgumentError) { Concurrent.new(key, limit: 0, lock_timeout: 10) }
      assert_raises(ArgumentError) { Concurrent.new(key, limit: 1, lock_timeout: 0) }
      assert_raises(ArgumentError) { Concurrent.new(key, limit: 1, lock_timeout: 10, ttl: -1) }
    end

    it 'rejects sub-second lock_timeout and ttl instead of truncating them' do
      error = assert_raises(ArgumentError) { Concurrent.new(key, limit: 1, lock_timeout: 2.5.seconds) }
      assert_equal 'expected lock_timeout to be a whole number of seconds', error.message

      error = assert_raises(ArgumentError) { Concurrent.new(key, limit: 1, lock_timeout: 10, ttl: 0.5.seconds) }
      assert_equal 'expected ttl to be a whole number of seconds', error.message
    end
  end
end
