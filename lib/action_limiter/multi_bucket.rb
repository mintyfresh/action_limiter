# typed: strict
# frozen_string_literal: true

module ActionLimiter
  # A fixed-interval (bucket) rate limiter that enforces a shared limit across multiple Redis
  # keys atomically.
  #
  # Checks *all* keys' current buckets before allowing an operation. If every bucket is under
  # the limit the operation is counted on each key in one atomic step; if *any* bucket is at
  # the limit nothing is modified:
  #
  #     limiter = ActionLimiter::MultiBucket.new(
  #       ["user:#{user_id}", "provider:#{provider_id}"],
  #       limit: 10,
  #       interval: 1.minute,
  #       wait_timeout: 5
  #     )
  #
  #     limiter.within_limit { call_external_api(...) }
  #
  # Each call issues a single +EVALSHA+ round-trip regardless of how many keys are checked.
  class MultiBucket < RedisLimiter
    extend T::Sig

    SCRIPT = Script.new('multi_bucket')

    T::Sig::WithoutRuntime.sig { returns(T::Array[String]) }
    attr_reader :keys

    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :limit

    # The bucket length in seconds
    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :interval

    sig do
      params(
        keys: T::Array[String],
        limit: Integer,
        interval: T.any(Integer, ActiveSupport::Duration),
        wait_timeout: T.any(Integer, ActiveSupport::Duration),
        redis: Redis,
        retry_options: T::Hash[Symbol, T.untyped]
      ).void
    end
    def initialize( # rubocop:disable Metrics/ParameterLists
      keys,
      limit:,
      interval:,
      wait_timeout: ActionLimiter.default_wait_timeout,
      redis: ActionLimiter.redis,
      retry_options: {}
    )
      interval_seconds = whole_seconds(:interval, interval)

      raise ArgumentError, 'expected at least one key to be provided' if keys.empty?
      raise ArgumentError, 'expected limit to be positive' if limit <= 0
      raise ArgumentError, 'expected interval to be positive' if interval_seconds <= 0

      super(wait_timeout:, redis:, retry_options:)
      @keys = keys
      @limit = limit
      @interval = T.let(interval_seconds, Integer)
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
      now = now_ms
      interval_ms = interval * 1000
      bucket_id = now / interval_ms
      bucket_keys = keys.map { |key| "#{key}:#{bucket_id}" }
      argv = [now, interval_ms, limit, (bucket_id + 1) * interval_ms]

      result = Integer(SCRIPT.call(redis, keys: bucket_keys, argv:))
      result.positive? ? nil : -result
    end
  end
end
