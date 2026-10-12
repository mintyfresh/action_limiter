# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class ConfigTest < TestCase
    after do
      ActionLimiter.redis = REDIS_URL
    end

    it 'accepts a Redis instance' do
      instance = ::Redis.new(url: REDIS_URL)
      ActionLimiter.redis = instance

      assert_same instance, ActionLimiter.redis
    end

    it 'accepts a URL string' do
      ActionLimiter.redis = 'redis://localhost:6379/14'

      assert_equal 14, ActionLimiter.redis.connection[:db]
    end

    it 'accepts a hash of connection options' do
      ActionLimiter.redis = { host: 'localhost', port: 6379, db: 13 }

      assert_equal 13, ActionLimiter.redis.connection[:db]
    end

    it 'exposes default settings' do
      assert_equal 0, ActionLimiter.default_wait_timeout
      assert_equal 10, ActionLimiter.default_concurrent_lock_ttl
      assert_equal 20, ActionLimiter.default_over_limit_retry_attempts
    end

    it 'has a version' do
      assert_equal '0.1.0', ActionLimiter::VERSION
    end
  end
end
