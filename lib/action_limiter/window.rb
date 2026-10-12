# typed: strict
# frozen_string_literal: true

module ActionLimiter
  # A sliding-window rate limiter backed by Redis.
  #
  # Permits at most +limit+ operations within any rolling +duration+ window. Once the limit is
  # reached, callers block until the oldest operation ages out — or until +wait_timeout+
  # elapses, at which point +ActionLimiter::OverLimit+ is raised.
  #
  #     ERP_LIMIT = ActionLimiter::Window.new('erp', limit: 50, duration: 30.seconds, wait_timeout: 5)
  #
  #     ERP_LIMIT.within_limit { erp_client.call(...) }
  #
  # Each call to +within_limit+ issues a single +EVALSHA+ round-trip to Redis.
  class Window < RedisLimiter
    extend T::Sig

    SCRIPT = Script.new('window')

    T::Sig::WithoutRuntime.sig { returns(String) }
    attr_reader :key

    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :limit

    # The window length in seconds
    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :duration

    sig do
      params(
        key: String,
        limit: Integer,
        duration: T.any(Integer, ActiveSupport::Duration),
        wait_timeout: T.any(Integer, ActiveSupport::Duration),
        redis: Connection,
        retry_options: T::Hash[Symbol, T.untyped],
        transform: KeyTransform
      ).void
    end
    def initialize( # rubocop:disable Metrics/ParameterLists
      key,
      limit:,
      duration:,
      wait_timeout: ActionLimiter.default_wait_timeout,
      redis: ActionLimiter.redis,
      retry_options: {},
      transform: nil
    )
      duration_seconds = whole_seconds(:duration, duration)

      raise ArgumentError, 'expected limit to be positive' if limit <= 0
      raise ArgumentError, 'expected duration to be positive' if duration_seconds <= 0

      super(wait_timeout:, redis:, retry_options:, transform:)
      @key = key
      @redis_key = T.let(redis_key(key), String)
      @limit = limit
      @duration = T.let(duration_seconds, Integer)
    end

    sig { override.returns(String) }
    def description
      key
    end

    T::Sig::WithoutRuntime.sig do
      override
        .type_parameters(:Result)
        .params(options: T.untyped, block: T.proc.params(handle: T.untyped).returns(T.type_parameter(:Result)))
        .returns(T.type_parameter(:Result))
    end
    def within_limit(**options, &block)
      reject_options!(options)
      wait_until_acquired { try_acquire }
      yield(nil)
    end

  private

    T::Sig::WithoutRuntime.sig { returns(T.nilable(Integer)) }
    def try_acquire
      result = Integer(
        SCRIPT.call(
          redis,
          keys: [@redis_key],
          argv: [now_ms, duration * 1000, limit, SecureRandom.uuid]
        )
      )
      result.positive? ? nil : -result
    end
  end
end
