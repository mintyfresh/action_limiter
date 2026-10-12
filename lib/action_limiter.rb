# typed: strict
# frozen_string_literal: true

require 'active_support'
require 'active_support/core_ext/integer/time'
require 'active_support/core_ext/numeric/time'
require 'active_support/duration'
require 'active_support/notifications'
require 'digest'
require 'openssl'
require 'redis'
require 'securerandom'
require 'sorbet-runtime'

require 'action_limiter/version'

module ActionLimiter
  autoload :ActionController, 'action_limiter/action_controller'
  autoload :AutomaticRetries, 'action_limiter/automatic_retries'
  autoload :Bucket, 'action_limiter/bucket'
  autoload :Concurrent, 'action_limiter/concurrent'
  autoload :GraphQL, 'action_limiter/graphql'
  autoload :Limiter, 'action_limiter/limiter'
  autoload :LockLost, 'action_limiter/lock_lost'
  autoload :MultiBucket, 'action_limiter/multi_bucket'
  autoload :MultiWindow, 'action_limiter/multi_window'
  autoload :OverLimit, 'action_limiter/over_limit'
  autoload :Points, 'action_limiter/points'
  autoload :RedisLimiter, 'action_limiter/redis_limiter'
  autoload :Script, 'action_limiter/script'
  autoload :Unlimited, 'action_limiter/unlimited'
  autoload :Window, 'action_limiter/window'

  @default_over_limit_retry_attempts = T.let(20, Integer)
  @default_wait_timeout = T.let(0, Integer)
  @default_concurrent_lock_ttl = T.let(10, Integer)

  class << self
    extend T::Sig

    sig { returns(Integer) }
    attr_accessor :default_over_limit_retry_attempts

    sig { returns(Integer) }
    attr_accessor :default_wait_timeout

    sig { returns(Integer) }
    attr_accessor :default_concurrent_lock_ttl

    # The Redis instance used by the limiters
    sig { returns(Redis) }
    def redis
      @redis ||= T.let(Redis.new, T.nilable(Redis))
    end

    # Set the Redis instance used by the limiters
    sig { params(redis: T.any(Redis, String, T::Hash[Symbol, T.untyped])).void }
    def redis=(redis)
      case redis
      when Redis
        @redis = redis
      when String
        @redis = Redis.new(url: redis)
      when Hash
        @redis = Redis.new(redis)
      else
        T.absurd(redis)
      end
    end
  end
end

require 'action_limiter/railtie' if defined?(Rails::Railtie)
