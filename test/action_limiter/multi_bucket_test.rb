# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class MultiBucketTest < TestCase
    before do
      suffix = ::SecureRandom.hex(8)
      @user_key = T.let("test:limiter:multi_bucket:user:#{suffix}", String)
      @global_key = T.let("test:limiter:multi_bucket:global:#{suffix}", String)
    end

    after do
      cleanup_pattern("#{user_key}:*")
      cleanup_pattern("#{global_key}:*")
    end

    sig { returns(String) }
    attr_reader :user_key

    sig { returns(String) }
    attr_reader :global_key

    sig { params(key: String, interval: Integer).returns(Integer) }
    def count(key, interval: 60)
      redis.get("#{key}:#{now_ms / (interval * 1000)}").to_i
    end

    it 'prefixes every key with the routing hash tag' do
      MultiBucket.new([user_key, global_key], limit: 2, interval: 60, routing: 'acct').within_limit { nil }

      assert_equal 1, count("{acct}#{user_key}")
      assert_equal 1, count("{acct}#{global_key}")
      assert_equal 0, count(user_key)
    ensure
      cleanup_pattern("{acct}#{user_key}:*")
      cleanup_pattern("{acct}#{global_key}:*")
    end

    it 'returns the block result when every key is under the limit' do
      limiter = MultiBucket.new([user_key, global_key], limit: 2, interval: 60)

      assert_equal :result, limiter.within_limit { :result }
    end

    it 'records the operation on every key' do
      MultiBucket.new([user_key, global_key], limit: 2, interval: 60).within_limit { nil }

      assert_equal 1, count(user_key)
      assert_equal 1, count(global_key)
    end

    it 'counts duplicate keys once per operation' do
      limiter = MultiBucket.new([user_key, user_key], limit: 3, interval: 3600)
      successes = 0

      3.times do
        limiter.within_limit { successes += 1 }
      rescue OverLimit
        nil
      end

      assert_equal 3, successes
      assert_equal 3, count(user_key, interval: 3600)
      assert_raises(OverLimit) { limiter.within_limit { :result } }
      assert_equal 3, count(user_key, interval: 3600)
    end

    it 'counts keys with the same transformed value once per operation' do
      limiter = MultiBucket.new(
        [user_key, global_key],
        limit: 3,
        interval: 3600,
        transform: -> (_value) { user_key }
      )
      successes = 0

      3.times do
        limiter.within_limit { successes += 1 }
      rescue OverLimit
        nil
      end

      assert_equal 3, successes
      assert_equal 3, count(user_key, interval: 3600)
      assert_raises(OverLimit) { limiter.within_limit { :result } }
      assert_equal 3, count(user_key, interval: 3600)
    end

    it 'rejects the operation without modifying any key when one key is at the limit' do
      Bucket.new(global_key, limit: 1, interval: 60).within_limit { nil }
      limiter = MultiBucket.new([user_key, global_key], limit: 1, interval: 60)

      error = assert_raises(OverLimit) { limiter.within_limit { :result } }

      assert_operator error.retry_after, :<=, 60
      assert_equal 0, count(user_key)
      assert_match(/#{::Regexp.escape(user_key)}, #{::Regexp.escape(global_key)}/, error.message)
    end

    it 'waits for the next bucket within wait_timeout' do
      limiter = MultiBucket.new([user_key, global_key], limit: 1, interval: 1, wait_timeout: 2)
      limiter.within_limit { nil }

      assert_equal :result, limiter.within_limit { :result }
    end

    it 'strictly enforces the limit under concurrent load' do
      limiter = MultiBucket.new([user_key, global_key], limit: 5, interval: 60)
      mutex = Thread::Mutex.new
      successes = 0

      Array.new(25) do
        Thread.new do
          limiter.within_limit { mutex.synchronize { successes += 1 } }
        rescue OverLimit
          nil
        end
      end.each(&:join)

      assert_equal 5, successes
    end

    it 'validates its arguments' do
      assert_raises(ArgumentError) { MultiBucket.new([], limit: 1, interval: 60) }
      assert_raises(ArgumentError) { MultiBucket.new([user_key], limit: 0, interval: 60) }
      assert_raises(ArgumentError) { MultiBucket.new([user_key], limit: 1, interval: 0) }
    end

    it 'rejects a sub-second interval instead of truncating it' do
      error = assert_raises(ArgumentError) { MultiBucket.new([user_key], limit: 1, interval: 0.5.seconds) }
      assert_equal 'expected interval to be a whole number of seconds', error.message
    end
  end
end
