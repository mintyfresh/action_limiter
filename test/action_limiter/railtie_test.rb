# typed: true
# frozen_string_literal: true

require 'test_helper'
require 'rails'
require 'action_limiter/railtie'

module ActionLimiter
  class RailtieTest < TestCase
    after do
      ActionLimiter.redis = REDIS_CONFIG
      ActionLimiter.default_wait_timeout = 0
      ActionLimiter.default_concurrent_lock_ttl = 10
      ActionLimiter.default_over_limit_retry_attempts = 20
    end

    def run_initializer(**options)
      config = ::ActiveSupport::OrderedOptions.new
      config[:action_limiter] = ::ActiveSupport::OrderedOptions.new.merge!(options)
      app = ::Struct.new(:config).new(config)

      ActionLimiter::Railtie.initializers.find { |i| i.name == 'action_limiter.configure' }.run(app)
    end

    it 'exposes config.action_limiter on the railtie' do
      assert_kind_of ::ActiveSupport::OrderedOptions, ActionLimiter::Railtie.config.action_limiter
    end

    it 'applies configured settings' do
      run_initializer(
        redis: 'redis://localhost:6379/14',
        default_wait_timeout: 5,
        default_concurrent_lock_ttl: 30,
        default_over_limit_retry_attempts: 3
      )

      assert_equal 14, ActionLimiter.redis.with { |connection| connection.connection[:db] }
      assert_equal 5, ActionLimiter.default_wait_timeout
      assert_equal 30, ActionLimiter.default_concurrent_lock_ttl
      assert_equal 3, ActionLimiter.default_over_limit_retry_attempts
    end

    it 'leaves unset settings unchanged' do
      redis = ActionLimiter.redis
      run_initializer(default_wait_timeout: 5)

      assert_same redis, ActionLimiter.redis
      assert_equal 10, ActionLimiter.default_concurrent_lock_ttl
    end

    it 'rejects unknown settings' do
      assert_raises(::NoMethodError) { run_initializer(bogus: 1) }
    end
  end
end
