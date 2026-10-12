# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class MultiWindowTest < TestCase
    before do
      suffix = ::SecureRandom.hex(8)
      @user_key = T.let("test:limiter:multi:user:#{suffix}", String)
      @global_key = T.let("test:limiter:multi:global:#{suffix}", String)
    end

    after do
      cleanup_keys(user_key, global_key)
    end

    sig { returns(String) }
    attr_reader :user_key

    sig { returns(String) }
    attr_reader :global_key

    it 'returns the block result when every key is under the limit' do
      limiter = MultiWindow.new([user_key, global_key], limit: 2, duration: 10)
      assert_equal :result, limiter.within_limit { :result }
    end

    it 'records the operation on every key' do
      MultiWindow.new([user_key, global_key], limit: 2, duration: 10).within_limit { nil }

      assert_equal 1, redis.zcard(user_key)
      assert_equal 1, redis.zcard(global_key)
    end

    it 'rejects the operation without modifying any key when one key is at the limit' do
      Window.new(global_key, limit: 1, duration: 10).within_limit { nil }
      limiter = MultiWindow.new([user_key, global_key], limit: 1, duration: 10)

      error = assert_raises(OverLimit) { limiter.within_limit { :result } }

      assert_same limiter, error.limiter
      assert_operator error.retry_after, :>, 9
      assert_equal 0, redis.zcard(user_key)
      assert_match(/#{::Regexp.escape(user_key)}, #{::Regexp.escape(global_key)}/, error.message)
    end

    it 'waits for the tightest constraint to clear' do
      limiter = MultiWindow.new([user_key, global_key], limit: 1, duration: 1, wait_timeout: 2)
      limiter.within_limit { nil }
      assert_equal :result, limiter.within_limit { :result }
    end

    it 'validates its arguments' do
      assert_raises(ArgumentError) { MultiWindow.new([], limit: 1, duration: 10) }
      assert_raises(ArgumentError) { MultiWindow.new([user_key], limit: 0, duration: 10) }
      assert_raises(ArgumentError) { MultiWindow.new([user_key], limit: 1, duration: 0) }
      assert_raises(ArgumentError) { MultiWindow.new([user_key], limit: 1, duration: 10, wait_timeout: -1) }
    end

    it 'rejects a sub-second duration instead of truncating it' do
      error = assert_raises(ArgumentError) { MultiWindow.new([user_key], limit: 1, duration: 0.5.seconds) }
      assert_equal 'expected duration to be a whole number of seconds', error.message
    end
  end
end
