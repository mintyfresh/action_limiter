# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class BucketTest < TestCase
    before do
      @key = T.let("test:limiter:bucket:#{::SecureRandom.hex(8)}", String)
    end

    after do
      cleanup_pattern("#{key}:*")
    end

    sig { returns(String) }
    attr_reader :key

    it 'returns the block result when under the limit' do
      limiter = Bucket.new(key, limit: 3, interval: 1)
      2.times { limiter.within_limit { nil } }
      assert_equal :result, limiter.within_limit { :result }
    end

    it 'raises OverLimit with the time until the next bucket' do
      limiter = Bucket.new(key, limit: 1, interval: 60)
      limiter.within_limit { nil }

      error = assert_raises(OverLimit) { limiter.within_limit { :result } }

      assert_same limiter, error.limiter
      assert_operator error.retry_after, :>, 0
      assert_operator error.retry_after, :<=, 60
      assert_match(/#{::Regexp.escape(key)}/, error.message)
    end

    it 'waits for the next bucket within wait_timeout' do
      limiter = Bucket.new(key, limit: 1, interval: 1, wait_timeout: 2)
      limiter.within_limit { nil }
      assert_equal :result, limiter.within_limit { :result }
    end

    it 'accepts an ActiveSupport::Duration interval' do
      limiter = Bucket.new(key, limit: 1, interval: 1.minute)
      assert_equal 60, limiter.interval

      limiter.within_limit { nil }
      error = assert_raises(OverLimit) { limiter.within_limit { nil } }
      assert_operator error.retry_after, :<=, 60
    end

    it 'aligns buckets to interval boundaries' do
      limiter = Bucket.new(key, limit: 1, interval: 60)
      limiter.within_limit { nil }
      assert_equal ["#{key}:#{now_ms / 60_000}"], redis.keys("#{key}:*")
    end

    it 'strictly enforces the limit under concurrent load' do
      limiter = Bucket.new(key, limit: 5, interval: 60)
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
      assert_raises(ArgumentError) { Bucket.new(key, limit: 0, interval: 1) }
      assert_raises(ArgumentError) { Bucket.new(key, limit: 1, interval: 0) }
      assert_raises(ArgumentError) { Bucket.new(key, limit: 1, interval: 1, wait_timeout: -1) }
    end

    it 'rejects a sub-second interval instead of truncating it' do
      error = assert_raises(ArgumentError) { Bucket.new(key, limit: 1, interval: 0.25.seconds) }
      assert_equal 'expected interval to be a whole number of seconds', error.message
    end
  end
end
