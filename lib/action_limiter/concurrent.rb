# typed: strict
# frozen_string_literal: true

module ActionLimiter
  # A concurrent rate limiter backed by Redis.
  #
  # Permits at most +limit+ operations to execute simultaneously. Each call to +within_limit+
  # acquires a token from a fixed-size pool before yielding and returns it when the block
  # completes (or raises). If a token cannot be acquired within +wait_timeout+ seconds,
  # +ActionLimiter::OverLimit+ is raised.
  #
  # A +lock_timeout+ ensures that tokens held by crashed processes are eventually reclaimed.
  # Operations must complete within +lock_timeout+ seconds — after that, another caller may
  # reclaim the token.
  #
  #     ERP_LIMIT = ActionLimiter::Concurrent.new('erp', limit: 50, lock_timeout: 30, wait_timeout: 5)
  #
  #     ERP_LIMIT.within_limit { erp_client.call(...) }
  #
  # == Data model
  #
  # * +key:tokens+ — a List with one entry per available slot.
  # * +key:held+ — a Sorted Set of acquisition IDs scored by their expiry timestamp.
  # * +key:pending+ — a Sorted Set of waiters blocked on +BRPOP+, scored by expiry. A token a
  #   waiter has popped but not yet recorded as held is accounted for here.
  #
  # == Performance
  #
  # The fast path (token available) is a single +EVALSHA+ round-trip. When the pool is empty,
  # +BRPOP+ blocks server-side until a token is released, on its own short-lived connection.
  class Concurrent < RedisLimiter
    extend T::Sig

    # A held slot, yielded to +within_limit+ blocks. Long-running holders call +renew+ to
    # extend the lock beyond +lock_timeout+:
    #
    #     LIMIT.within_limit do |lease|
    #       stream.each_chunk { |chunk| write(chunk); lease.renew }
    #     end
    class Lease
      extend T::Sig

      sig { returns(String) }
      attr_reader :acquisition_id

      sig { params(limiter: Concurrent, acquisition_id: String).void }
      def initialize(limiter, acquisition_id)
        @limiter = limiter
        @acquisition_id = acquisition_id
      end

      # Extends the lock to +lock_timeout+ from now. Raises +ActionLimiter::LockLost+ if the lock
      # has already been reclaimed.
      sig { void }
      def renew
        @limiter.renew(acquisition_id)
      end

      sig { returns(T::Boolean) }
      def held?
        @limiter.held?(acquisition_id)
      end
    end

    # How long a waiter's pending entry outlives its wait, covering the BRPOP round-trip
    PENDING_GRACE_MS = 5_000

    INIT_SCRIPT = Script.new('concurrent_init')
    ACQUIRE_SCRIPT = Script.new('concurrent_acquire')
    BRPOP_ACQUIRE_SCRIPT = Script.new('concurrent_brpop_acquire')
    RELEASE_SCRIPT = Script.new('concurrent_release')
    RENEW_SCRIPT = Script.new('concurrent_renew')

    T::Sig::WithoutRuntime.sig { returns(String) }
    attr_reader :key

    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :limit

    # Seconds a lock may be held before another caller can reclaim it
    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :lock_timeout

    sig do
      params(
        key: String,
        limit: Integer,
        lock_timeout: T.any(Integer, ActiveSupport::Duration),
        wait_timeout: T.any(Integer, ActiveSupport::Duration),
        ttl: T.any(Integer, ActiveSupport::Duration),
        redis: Redis,
        retry_options: T::Hash[Symbol, T.untyped],
        transform: KeyTransform
      ).void
    end
    def initialize( # rubocop:disable Metrics/ParameterLists
      key,
      limit:,
      lock_timeout:,
      wait_timeout: ActionLimiter.default_wait_timeout,
      ttl: ActionLimiter.default_concurrent_lock_ttl,
      redis: ActionLimiter.redis,
      retry_options: {},
      transform: nil
    )
      lock_seconds = whole_seconds(:lock_timeout, lock_timeout)
      ttl_seconds = whole_seconds(:ttl, ttl)

      raise ArgumentError, 'expected limit to be positive' if limit <= 0
      raise ArgumentError, 'expected lock_timeout to be positive' if lock_seconds <= 0

      super(wait_timeout:, redis:, retry_options:, transform:)
      @key = key
      @limit = limit
      @lock_timeout = T.let(lock_seconds, Integer)
      base_key = redis_key(key)
      @keys = T.let(["#{base_key}:tokens", "#{base_key}:held", "#{base_key}:pending"], T::Array[String])
      @key_ttl = T.let(@lock_timeout + self.wait_timeout + ttl_seconds, Integer)

      INIT_SCRIPT.call(redis, keys: @keys, argv: [limit, now_ms, @key_ttl])
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
      acquisition_id = acquire

      begin
        yield(Lease.new(self, acquisition_id))
      ensure
        release(acquisition_id)
      end
    end

    # Extends a held lock. Prefer +Lease#renew+.
    T::Sig::WithoutRuntime.sig { params(acquisition_id: String).void }
    def renew(acquisition_id)
      argv = [now_ms, lock_timeout * 1000, acquisition_id, @key_ttl]
      return if RENEW_SCRIPT.call(redis, keys: @keys, argv:)

      instrument(:lock_lost)
      raise LockLost, self
    end

    # Whether a lock is still held. Prefer +Lease#held?+.
    T::Sig::WithoutRuntime.sig { params(acquisition_id: String).returns(T::Boolean) }
    def held?(acquisition_id)
      !redis.zscore(held_key, acquisition_id).nil?
    end

  private

    T::Sig::WithoutRuntime.sig { returns(String) }
    def acquire
      acquisition_id = SecureRandom.hex(16)
      started_at = monotonic_now
      deadline = started_at + wait_timeout

      loop do
        remaining = deadline - monotonic_now
        return acquired(acquisition_id, started_at) if try_acquire(acquisition_id, remaining)
        raise over_limit_error(lock_timeout.to_f) if remaining <= 0

        if blocking_pop(remaining)
          BRPOP_ACQUIRE_SCRIPT.call(redis, keys: @keys, argv: [now_ms, lock_timeout * 1000, acquisition_id, @key_ttl])
          return acquired(acquisition_id, started_at)
        end

        redis.zrem(pending_key, acquisition_id)
      end
    end

    # Runs the acquire script; when +remaining+ wait time is left, a failed attempt also
    # registers the caller as a pending waiter
    T::Sig::WithoutRuntime.sig { params(acquisition_id: String, remaining: Float).returns(T::Boolean) }
    def try_acquire(acquisition_id, remaining)
      now = now_ms
      pending_expiry_ms = remaining.positive? ? now + (remaining * 1000).ceil + PENDING_GRACE_MS : 0
      argv = [now, lock_timeout * 1000, acquisition_id, @key_ttl, limit, pending_expiry_ms]

      ACQUIRE_SCRIPT.call(redis, keys: @keys, argv:) ? true : false
    end

    T::Sig::WithoutRuntime.sig { params(acquisition_id: String, started_at: Float).returns(String) }
    def acquired(acquisition_id, started_at)
      instrument(:acquire, waited: monotonic_now - started_at)
      acquisition_id
    end

    # BRPOP runs on its own short-lived connection: redis-rb serialises commands on a shared
    # client, so blocking on it would stall every other thread using that client. The timeout
    # is clamped to 1ms because a BRPOP timeout of 0 blocks forever.
    T::Sig::WithoutRuntime.sig { params(timeout: Float).returns(T.nilable(T::Array[String])) }
    def blocking_pop(timeout)
      timeout = [timeout, 0.001].max.round(3)
      connection = redis._client.config.new_client

      begin
        connection.blocking_call_v(timeout, ['BRPOP', tokens_key, timeout])
      ensure
        connection.close
      end
    end

    # A failed release must not mask an exception raised by the block, so it is reported and
    # swallowed. The lock then expires through +lock_timeout+.
    T::Sig::WithoutRuntime.sig { params(acquisition_id: String).void }
    def release(acquisition_id)
      RELEASE_SCRIPT.call(redis, keys: @keys, argv: [acquisition_id, @key_ttl, limit])
    rescue Redis::BaseError => error
      instrument(:release_failed, error:)
    end

    T::Sig::WithoutRuntime.sig { returns(String) }
    def tokens_key
      T.must(@keys[0])
    end

    T::Sig::WithoutRuntime.sig { returns(String) }
    def held_key
      T.must(@keys[1])
    end

    T::Sig::WithoutRuntime.sig { returns(String) }
    def pending_key
      T.must(@keys[2])
    end
  end
end
