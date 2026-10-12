# typed: strict
# frozen_string_literal: true

module ActionLimiter
  # Shared plumbing for limiters backed by Redis: waiting, instrumentation, and clocks.
  #
  # == Clock sensitivity
  #
  # Timestamps are taken from +Process.clock_gettime(CLOCK_REALTIME)+ on the calling process.
  # All machines sharing a limiter should synchronise their clocks via NTP.
  class RedisLimiter < Limiter
    extend T::Sig
    extend T::Helpers

    abstract!

    # Seconds to wait for capacity before raising +ActionLimiter::OverLimit+
    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :wait_timeout

    T::Sig::WithoutRuntime.sig { returns(Redis) }
    attr_reader :redis

    sig do
      params(
        wait_timeout: T.any(Integer, ActiveSupport::Duration),
        redis: Redis,
        retry_options: T::Hash[Symbol, T.untyped]
      ).void
    end
    def initialize(wait_timeout:, redis:, retry_options:)
      wait_seconds = whole_seconds(:wait_timeout, wait_timeout)
      raise ArgumentError, 'expected wait_timeout to be non-negative' if wait_seconds.negative?

      super(retry_options:)
      @wait_timeout = T.let(wait_seconds, Integer)
      @redis = redis
    end

  private

    # Converts a duration argument to whole seconds, refusing to silently truncate a fractional
    # one (e.g. +0.5.seconds+ would otherwise become 0)
    sig { params(name: Symbol, value: T.any(Integer, ActiveSupport::Duration)).returns(Integer) }
    def whole_seconds(name, value)
      raise ArgumentError, "expected #{name} to be a whole number of seconds" unless (value.to_f % 1).zero?

      value.to_i
    end

    # Repeatedly attempts acquisition until it succeeds or +wait_timeout+ elapses. The block
    # returns nil on success, or the number of milliseconds until an attempt could succeed.
    # Sleeps exactly that long between attempts; it does not poll.
    T::Sig::WithoutRuntime.sig { params(block: T.proc.returns(T.nilable(Integer))).void }
    def wait_until_acquired(&block)
      started_at = monotonic_now
      deadline = started_at + wait_timeout

      loop do
        retry_after_ms = yield
        return instrument(:acquire, waited: monotonic_now - started_at) if retry_after_ms.nil?

        retry_after = retry_after_ms / 1000.0
        remaining = deadline - monotonic_now
        raise over_limit_error(retry_after) if remaining <= 0

        sleep([retry_after, remaining].min)
      end
    end

    T::Sig::WithoutRuntime.sig { params(options: T::Hash[Symbol, T.untyped]).void }
    def reject_options!(options)
      raise ArgumentError, "unknown options for #{self.class}: #{options.keys.join(', ')}" if options.any?
    end

    T::Sig::WithoutRuntime.sig { params(retry_after: Float).returns(OverLimit) }
    def over_limit_error(retry_after)
      error = OverLimit.new(self, retry_after:)
      instrument(:over_limit, error:)
      error
    end

    T::Sig::WithoutRuntime.sig { params(event: Symbol, payload: T.untyped).void }
    def instrument(event, **payload)
      ActiveSupport::Notifications.instrument("#{event}.action_limiter", limiter: self, **payload)
    end

    T::Sig::WithoutRuntime.sig { returns(Integer) }
    def now_ms
      (Process.clock_gettime(Process::CLOCK_REALTIME) * 1000).to_i
    end

    T::Sig::WithoutRuntime.sig { returns(Float) }
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
    end
  end
end
