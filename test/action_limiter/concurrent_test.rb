# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class ConcurrentTest < TestCase
    before do
      @key = T.let("test:limiter:concurrent:#{::SecureRandom.hex(8)}", String)
    end

    after do
      cleanup_keys(tokens_key, held_key, pending_key)
    end

    sig { returns(String) }
    attr_reader :key

    sig { returns(String) }
    def tokens_key = "#{key}:tokens"

    sig { returns(String) }
    def held_key = "#{key}:held"

    sig { returns(String) }
    def pending_key = "#{key}:pending"

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

    it 'does not add extra tokens on re-initialization' do
      Concurrent.new(key, limit: 3, lock_timeout: 10)
      Concurrent.new(key, limit: 3, lock_timeout: 10)

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
      assert_equal 0, redis.zcard(pending_key)
    end

    it 'removes its pending entry when the wait times out' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10, wait_timeout: 1)
      occupy_token

      assert_raises(OverLimit) { limiter.within_limit { nil } }
      assert_equal 0, redis.zcard(pending_key)
    end

    it 'does not block other threads sharing the Redis client while waiting' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10, wait_timeout: 1)
      occupy_token
      waiter = Thread.new do
        limiter.within_limit { nil }
      rescue OverLimit
        nil
      end
      sleep(0.1)

      started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      redis.ping

      assert_operator ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at, :<, 0.2
      waiter.join
    end

    it 'never blocks indefinitely when BRPOP is given a zero timeout' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      occupy_token

      started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      assert_nil limiter.send(:blocking_pop, 0.0)
      assert_operator ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at, :<, 0.5
    end

    it 'self-heals a token lost with no waiter in flight' do
      limiter = Concurrent.new(key, limit: 2, lock_timeout: 10)
      redis.lpop(tokens_key)

      assert_equal :healed, limiter.within_limit { :healed }
    end

    it 'does not mint a token while a live waiter holds one in flight' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      # The waiter has BRPOP'd the only token but not yet run BRPOP_ACQUIRE
      redis.lpop(tokens_key)
      redis.zadd(pending_key, now_ms + 10_000, 'waiter')

      assert_raises(OverLimit) { limiter.within_limit { :admitted } }
      assert_equal 0, redis.llen(tokens_key)
    end

    it 'heals the token of a waiter that crashed in flight once its pending entry expires' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      redis.lpop(tokens_key)
      redis.zadd(pending_key, now_ms - 1, 'crashed-waiter')

      assert_equal :healed, limiter.within_limit { :healed }
      assert_equal 0, redis.zcard(pending_key)
    end

    it 'trims surplus tokens when the limit is lowered' do
      Concurrent.new(key, limit: 5, lock_timeout: 10)
      limiter = Concurrent.new(key, limit: 2, lock_timeout: 10, wait_timeout: 5)

      assert_equal 2, redis.llen(tokens_key)

      assert_operator peak_concurrency(limiter, threads: 5, iterations: 1, hold: 0.1), :<=, 2
    end

    it 'trims a surplus token found in the pool on acquire' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      redis.rpush(tokens_key, '1')

      limiter.within_limit { nil }

      assert_equal 1, redis.llen(tokens_key)
    end

    it 'reclaims a token minted for an in-flight waiter whose pending entry expired' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      # The waiter popped the only token, then its pending entry was pruned (clock skew)
      redis.lpop(tokens_key)
      redis.zadd(pending_key, now_ms - 1, 'waiter')

      limiter.within_limit do
        Concurrent::BRPOP_ACQUIRE_SCRIPT.call(
          redis, keys: [tokens_key, held_key, pending_key], argv: [now_ms, 10_000, 'waiter', 30]
        )
      end

      assert_equal 0, redis.llen(tokens_key)

      limiter.send(:release, 'waiter')

      assert_equal 1, redis.llen(tokens_key)
    end

    it 'never exceeds the limit under contention and settles back to the limit' do
      limiter = Concurrent.new(key, limit: 3, lock_timeout: 10, wait_timeout: 5)

      assert_operator peak_concurrency(limiter, threads: 20, iterations: 5, hold: 0.01), :<=, 3
      assert_equal 3, redis.llen(tokens_key)
      assert_equal 0, redis.zcard(pending_key)
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
    end

    it 'rejects sub-second lock_timeout and ttl instead of truncating them' do
      error = assert_raises(ArgumentError) { Concurrent.new(key, limit: 1, lock_timeout: 2.5.seconds) }
      assert_equal 'expected lock_timeout to be a whole number of seconds', error.message

      error = assert_raises(ArgumentError) { Concurrent.new(key, limit: 1, lock_timeout: 10, ttl: 0.5.seconds) }
      assert_equal 'expected ttl to be a whole number of seconds', error.message
    end
  end
end
