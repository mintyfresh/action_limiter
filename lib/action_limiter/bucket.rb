# typed: strict
# frozen_string_literal: true

module ActionLimiter
  # A fixed-interval (bucket) rate limiter backed by Redis.
  #
  # Permits at most +limit+ operations within each discrete interval, aligned to clock
  # boundaries. Unlike +ActionLimiter::Window+, each interval is independent: 5 operations at
  # 12:42:51.999 and 5 more at 12:42:52.000 fall in different one-second buckets.
  #
  #     PAYMENT_LIMIT = ActionLimiter::Bucket.new('payment-api', limit: 30, interval: 1.second, wait_timeout: 5)
  #
  #     PAYMENT_LIMIT.within_limit { payment_client.call(...) }
  #
  # Each bucket is a counter at +key:floor(now_ms / interval_ms)+ with a TTL of twice the
  # interval. When over the limit, callers sleep exactly until the next bucket begins.
  class Bucket < RedisLimiter
    extend T::Sig

    # Increments first and checks after, saving a +GET+. Overshooting the counter is harmless
    # because the bucket key expires on its own.
    SCRIPT = Script.new('bucket')

    T::Sig::WithoutRuntime.sig { returns(String) }
    attr_reader :key

    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :limit

    # The bucket length in seconds
    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :interval

    sig do
      params(
        key: String,
        limit: Integer,
        interval: T.any(Integer, ActiveSupport::Duration),
        wait_timeout: T.any(Integer, ActiveSupport::Duration),
        redis: Redis,
        retry_options: T::Hash[Symbol, T.untyped]
      ).void
    end
    def initialize( # rubocop:disable Metrics/ParameterLists
      key,
      limit:,
      interval:,
      wait_timeout: ActionLimiter.default_wait_timeout,
      redis: ActionLimiter.redis,
      retry_options: {}
    )
      raise ArgumentError, 'expected limit to be positive' if limit <= 0
      raise ArgumentError, 'expected interval to be positive' if interval.to_i <= 0

      super(wait_timeout:, redis:, retry_options:)
      @key = key
      @limit = limit
      @interval = T.let(interval.to_i, Integer)
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
      now = now_ms
      interval_ms = interval * 1000
      bucket_id = now / interval_ms
      argv = [now, interval_ms, limit, (bucket_id + 1) * interval_ms]

      result = Integer(SCRIPT.call(redis, keys: ["#{key}:#{bucket_id}"], argv:))
      result.positive? ? nil : -result
    end
  end
end
