# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class ConcurrentLeaseTest < TestCase
    before do
      @key = T.let("test:limiter:lease:#{::SecureRandom.hex(8)}", String)
    end

    after do
      cleanup_keys(held_key, "{#{key}}:tokens", "{#{key}}:claimed")
    end

    sig { returns(String) }
    attr_reader :key

    sig { returns(String) }
    def held_key = "{#{key}}:held"

    it 'yields a held lease' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)

      limiter.within_limit do |lease|
        assert_kind_of Concurrent::Lease, lease
        assert_predicate lease, :held?
      end
    end

    it 'extends the lock expiry on renew' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)

      limiter.within_limit do |lease|
        before = redis.zscore(held_key, lease.acquisition_id)
        sleep(0.05)
        lease.renew

        assert_operator redis.zscore(held_key, lease.acquisition_id), :>, before
      end
    end

    it 'raises LockLost and instruments lock_lost when the lock was reclaimed' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)

      events = capture_events('lock_lost.action_limiter') do
        limiter.within_limit do |lease|
          redis.zrem(held_key, lease.acquisition_id)

          refute_predicate lease, :held?
          assert_raises(LockLost) { lease.renew }
        end
      end

      assert_equal 1, events.size
    end

    it 'reports a lease used after its block returned as lost' do
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10)
      escaped = limiter.within_limit { |lease| lease }

      refute_predicate escaped, :held?
      assert_raises(LockLost) { escaped.renew }
    end

    it 'reports a failed release without masking the block error' do
      broken = ::Redis.new(url: REDIS_URL)
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10, redis: broken)

      events = capture_events('release_failed.action_limiter') do
        assert_raises(RuntimeError) do
          limiter.within_limit do
            broken.define_singleton_method(:evalsha) { |*, **| raise ::Redis::ConnectionError, 'down' }
            raise 'boom'
          end
        end
      end

      assert_equal 1, events.size
      assert_kind_of ::Redis::ConnectionError, T.must(events.first).payload.fetch(:error)
    end

    it 'reports a release that cannot check out a connection without masking the block error' do
      pool = ::ConnectionPool.new(size: 1, timeout: 0.1) { ::Redis.new(url: REDIS_URL) }
      limiter = Concurrent.new(key, limit: 1, lock_timeout: 10, redis: pool)
      checked_out = ::Thread::Queue.new
      done = ::Thread::Queue.new

      events = capture_events('release_failed.action_limiter') do
        assert_raises(RuntimeError) do
          limiter.within_limit do
            Thread.new do
              pool.with do
                checked_out << true
                done.pop
              end
            end
            checked_out.pop
            raise 'boom'
          end
        end
      end
      done << true

      assert_equal 1, events.size
      assert_kind_of ::ConnectionPool::TimeoutError, T.must(events.first).payload.fetch(:error)
    end
  end
end
