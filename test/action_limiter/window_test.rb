# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class WindowTest < TestCase
    before do
      @key = T.let("test:limiter:window:#{::SecureRandom.hex(8)}", String)
    end

    after do
      cleanup_keys(key)
    end

    sig { returns(String) }
    attr_reader :key

    it 'returns the block result when under the limit' do
      limiter = Window.new(key, limit: 3, duration: 10)
      assert_equal :result, limiter.within_limit { :result }
    end

    it 'returns the block result when multiple operations are under the limit' do
      limiter = Window.new(key, limit: 3, duration: 10)
      2.times { limiter.within_limit { nil } }
      assert_equal :result, limiter.within_limit { :result }
    end

    it 'yields nil' do
      limiter = Window.new(key, limit: 1, duration: 10)
      assert_nil(limiter.within_limit { |handle| handle })
    end

    it 'raises OverLimit when the limit is reached' do
      limiter = Window.new(key, limit: 1, duration: 10, retry_options: { attempts: 3 })
      limiter.within_limit { nil }

      error = assert_raises(OverLimit) { limiter.within_limit { :result } }

      assert_same limiter, error.limiter
      assert_operator error.retry_after, :>, 9
      assert_operator error.retry_after, :<=, 10
      assert_equal({ attempts: 3 }, error.retry_options)
      assert_match(/#{::Regexp.escape(key)}/, error.message)
    end

    it 'succeeds once wait_timeout allows the oldest entry to age out' do
      limiter = Window.new(key, limit: 1, duration: 1, wait_timeout: 2)
      limiter.within_limit { nil }
      assert_equal :result, limiter.within_limit { :result }
    end

    it 'accepts ActiveSupport::Duration arguments' do
      limiter = Window.new(key, limit: 1, duration: 1.second, wait_timeout: 2.seconds)

      assert_equal 1, limiter.duration
      assert_equal 2, limiter.wait_timeout
      limiter.within_limit { nil }
      assert_equal :result, limiter.within_limit { :result }
    end

    it 'tracks limits independently per key' do
      other_key = "test:limiter:window:#{::SecureRandom.hex(8)}"
      Window.new(key, limit: 1, duration: 10).within_limit { nil }

      assert_equal :ok, Window.new(other_key, limit: 1, duration: 10).within_limit { :ok }
    ensure
      cleanup_keys(T.must(other_key))
    end

    it 'reloads the Lua script after the script cache is flushed' do
      limiter = Window.new(key, limit: 1, duration: 10)
      limiter.within_limit { nil }
      redis.script(:flush)

      assert_raises(OverLimit) { limiter.within_limit { :result } }
    end

    it 'rejects unknown within_limit options' do
      assert_raises(ArgumentError) { Window.new(key, limit: 1, duration: 10).within_limit(estimate: 1) { nil } }
    end

    it 'validates its arguments' do
      assert_raises(ArgumentError) { Window.new(key, limit: 0, duration: 10) }
      assert_raises(ArgumentError) { Window.new(key, limit: 1, duration: 0) }
      assert_raises(ArgumentError) { Window.new(key, limit: 1, duration: 10, wait_timeout: -1) }
    end

    it 'instruments acquire' do
      events = capture_events('acquire.action_limiter') { Window.new(key, limit: 1, duration: 10).within_limit { nil } }
      assert_equal 1, events.size
    end
  end
end
