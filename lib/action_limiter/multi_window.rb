# typed: strict
# frozen_string_literal: true

module ActionLimiter
  # A sliding-window rate limiter that enforces a shared limit across multiple Redis keys
  # atomically.
  #
  # Checks *all* keys before allowing an operation. If every key is under the limit the
  # operation is recorded on each key in one atomic step; if *any* key is at the limit nothing
  # is modified. Useful when one action must respect several independent limits at once:
  #
  #     limiter = ActionLimiter::MultiWindow.new(
  #       ["user:#{user_id}", "provider:#{provider_id}"],
  #       limit: 10,
  #       duration: 60.seconds,
  #       wait_timeout: 5
  #     )
  #
  #     limiter.within_limit { call_external_api(...) }
  #
  # Each call issues a single +EVALSHA+ round-trip regardless of how many keys are checked.
  class MultiWindow < RedisLimiter
    extend T::Sig

    SCRIPT = Script.new('multi_window')

    T::Sig::WithoutRuntime.sig { returns(T::Array[String]) }
    attr_reader :keys

    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :limit

    # The window length in seconds
    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :duration

    sig do
      params(
        keys: T::Array[String],
        limit: Integer,
        duration: T.any(Integer, ActiveSupport::Duration),
        wait_timeout: T.any(Integer, ActiveSupport::Duration),
        redis: Redis,
        retry_options: T::Hash[Symbol, T.untyped],
        transform: KeyTransform
      ).void
    end
    def initialize( # rubocop:disable Metrics/ParameterLists
      keys,
      limit:,
      duration:,
      wait_timeout: ActionLimiter.default_wait_timeout,
      redis: ActionLimiter.redis,
      retry_options: {},
      transform: nil
    )
      duration_seconds = whole_seconds(:duration, duration)

      raise ArgumentError, 'expected at least one key to be provided' if keys.empty?
      raise ArgumentError, 'expected limit to be positive' if limit <= 0
      raise ArgumentError, 'expected duration to be positive' if duration_seconds <= 0

      super(wait_timeout:, redis:, retry_options:, transform:)
      @keys = keys
      @redis_keys = T.let(keys.map { |key| redis_key(key) }, T::Array[String])
      @limit = limit
      @duration = T.let(duration_seconds, Integer)
    end

    sig { override.returns(String) }
    def description
      keys.join(', ')
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
      result = Integer(SCRIPT.call(redis, keys: @redis_keys, argv: [now_ms, duration * 1000, limit, SecureRandom.uuid]))
      result.positive? ? nil : -result
    end
  end
end
