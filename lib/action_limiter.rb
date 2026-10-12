# typed: strict
# frozen_string_literal: true

require 'active_support'
require 'active_support/core_ext/integer/time'
require 'active_support/core_ext/numeric/time'
require 'active_support/duration'
require 'active_support/notifications'
require 'digest'
require 'redis'
require 'securerandom'
require 'sorbet-runtime'

require 'action_limiter/version'

module ActionLimiter
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
