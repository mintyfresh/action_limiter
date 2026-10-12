# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class ConfigTest < TestCase
    after do
      ActionLimiter.redis = REDIS_CONFIG
    end

    it 'accepts a Redis instance' do
      instance = ::Redis.new(url: REDIS_URL)
      ActionLimiter.redis = instance

      assert_same instance, ActionLimiter.redis
    end

    it 'accepts a ConnectionPool' do
      pool = ::ConnectionPool.new { ::Redis.new(url: REDIS_URL) }
      ActionLimiter.redis = pool

      assert_same pool, ActionLimiter.redis
    end

    it 'wraps a URL string in a ConnectionPool' do
      ActionLimiter.redis = 'redis://localhost:6379/14'

      assert_kind_of ::ConnectionPool, ActionLimiter.redis
      assert_equal 14, ActionLimiter.redis.with { |connection| connection.connection[:db] }
    end

    it 'wraps a hash of connection options in a ConnectionPool sized by its pool entry' do
      ActionLimiter.redis = { host: 'localhost', port: 6379, db: 13, pool: { size: 2 } }

      assert_kind_of ::ConnectionPool, ActionLimiter.redis
      assert_equal 2, T.cast(ActionLimiter.redis, ::ConnectionPool).size
      assert_equal 13, ActionLimiter.redis.with { |connection| connection.connection[:db] }
    end

    it 'sizes the pool from RAILS_MAX_THREADS when it is set' do
      original = ENV.fetch('RAILS_MAX_THREADS', nil)
      ENV['RAILS_MAX_THREADS'] = '7'
      ActionLimiter.redis = REDIS_URL

      assert_equal 7, T.cast(ActionLimiter.redis, ::ConnectionPool).size
    ensure
      ENV['RAILS_MAX_THREADS'] = original
    end

    it 'prefers an explicit pool size over RAILS_MAX_THREADS' do
      original = ENV.fetch('RAILS_MAX_THREADS', nil)
      ENV['RAILS_MAX_THREADS'] = '7'
      ActionLimiter.redis = { url: REDIS_URL, pool: { size: 2 } }

      assert_equal 2, T.cast(ActionLimiter.redis, ::ConnectionPool).size
    ensure
      ENV['RAILS_MAX_THREADS'] = original
    end

    it 'exposes default settings' do
      assert_equal 0, ActionLimiter.default_wait_timeout
      assert_equal 10, ActionLimiter.default_concurrent_lock_ttl
      assert_equal 20, ActionLimiter.default_over_limit_retry_attempts
    end

    it 'has a version' do
      assert_equal '0.2.0', ActionLimiter::VERSION
    end
  end
end
