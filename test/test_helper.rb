# typed: strict
# frozen_string_literal: true

require 'bundler/setup'
require 'sorbet-runtime'
require 'minitest/autorun'
require 'action_limiter'

module ActionLimiter
  class TestCase < ::Minitest::Spec
    extend T::Sig

    REDIS_URL = T.let(ENV.fetch('REDIS_URL', 'redis://localhost:6379/15'), String)
    REDIS_CONFIG = T.let({ url: REDIS_URL, pool: { size: 25 } }.freeze, T::Hash[Symbol, T.untyped])
    REDIS = ::Redis.new(url: REDIS_URL)

    sig { returns(::Redis) }
    def redis
      REDIS
    end

    sig { params(keys: String).void }
    def cleanup_keys(*keys)
      redis.del(*T.unsafe(keys)) if keys.any?
    end

    sig { params(pattern: String).void }
    def cleanup_pattern(pattern)
      keys = redis.keys(pattern)
      redis.del(*T.unsafe(keys)) if keys.any?
    end

    sig { params(name: String, block: T.proc.void).returns(T::Array[::ActiveSupport::Notifications::Event]) }
    def capture_events(name, &block)
      events = T.let([], T::Array[::ActiveSupport::Notifications::Event])
      callback = -> (event) { events << event }
      ::ActiveSupport::Notifications.subscribed(callback, name, &block)
      events
    end

    sig { returns(Integer) }
    def now_ms
      (::Process.clock_gettime(::Process::CLOCK_REALTIME) * 1000).to_i
    end
  end
end

ActionLimiter.redis = ActionLimiter::TestCase::REDIS_CONFIG
