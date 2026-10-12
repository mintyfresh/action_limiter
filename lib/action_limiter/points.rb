# typed: strict
# frozen_string_literal: true

module ActionLimiter
  # A points-based rate limiter backed by Redis, for APIs that charge each request a variable
  # cost (e.g. GraphQL query complexity).
  #
  # The bucket holds up to +capacity+ points and restores +restore_rate+ points per second.
  # Each call reserves an +estimate+ up front; once the real cost is known, report it so the
  # difference is refunded or debited:
  #
  #     SHOPIFY = ActionLimiter::Points.new('shopify', capacity: 1000, restore_rate: 50, wait_timeout: 5)
  #
  #     SHOPIFY.within_limit(estimate: 200) do |handle|
  #       response = client.query(...)
  #       handle.points_used(response.cost.actual)
  #     end
  #
  # An underestimate can take the balance negative; that debt delays later callers, as the
  # remote API would. If +points_used+ is never called (including when the block raises), the
  # estimate stands.
  class Points < RedisLimiter
    extend T::Sig

    # Reports the actual cost of a +within_limit+ call
    class Handle
      extend T::Sig

      sig { params(limiter: Points, estimate: Numeric).void }
      def initialize(limiter, estimate)
        @limiter = limiter
        @estimate = estimate
        @used = T.let(false, T::Boolean)
      end

      sig { params(actual: Numeric).void }
      def points_used(actual)
        raise ArgumentError, 'points_used was already called' if @used
        raise ArgumentError, 'expected actual to be non-negative' if actual.negative?

        @used = true
        @limiter.adjust(@estimate - actual)
      end
    end

    ACQUIRE_SCRIPT = Script.new('points_acquire')
    ADJUST_SCRIPT = Script.new('points_adjust')

    T::Sig::WithoutRuntime.sig { returns(String) }
    attr_reader :key

    T::Sig::WithoutRuntime.sig { returns(Integer) }
    attr_reader :capacity

    # Points restored per second
    T::Sig::WithoutRuntime.sig { returns(Float) }
    attr_reader :restore_rate

    T::Sig::WithoutRuntime.sig { returns(T.nilable(Numeric)) }
    attr_reader :default_estimate

    sig do
      params(
        key: String,
        capacity: Integer,
        restore_rate: Numeric,
        default_estimate: T.nilable(Numeric),
        wait_timeout: T.any(Integer, ActiveSupport::Duration),
        redis: Redis,
        retry_options: T::Hash[Symbol, T.untyped]
      ).void
    end
    def initialize( # rubocop:disable Metrics/ParameterLists
      key,
      capacity:,
      restore_rate:,
      default_estimate: nil,
      wait_timeout: ActionLimiter.default_wait_timeout,
      redis: ActionLimiter.redis,
      retry_options: {}
    )
      raise ArgumentError, 'expected capacity to be positive' if capacity <= 0
      raise ArgumentError, 'expected restore_rate to be positive' unless restore_rate.positive?

      super(wait_timeout:, redis:, retry_options:)
      @key = key
      @capacity = capacity
      @restore_rate = T.let(restore_rate.to_f, Float)
      @default_estimate = default_estimate
      validate_estimate!(default_estimate) unless default_estimate.nil?
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
      estimate = options.fetch(:estimate, default_estimate)
      raise ArgumentError, 'missing keyword: :estimate' if estimate.nil?

      reject_options!(options.except(:estimate))
      validate_estimate!(estimate)

      wait_until_acquired { try_acquire(estimate) }
      yield(Handle.new(self, estimate))
    end

    # Applies a correction to the balance: positive refunds, negative debits. Prefer
    # +Handle#points_used+.
    T::Sig::WithoutRuntime.sig { params(delta: Numeric).void }
    def adjust(delta)
      ADJUST_SCRIPT.call(redis, keys: [key], argv: [now_ms, capacity, restore_rate, delta])
    end

  private

    T::Sig::WithoutRuntime.sig { params(estimate: Numeric).returns(T.nilable(Integer)) }
    def try_acquire(estimate)
      wait_ms = Integer(ACQUIRE_SCRIPT.call(redis, keys: [key], argv: [now_ms, capacity, restore_rate, estimate]))
      wait_ms.zero? ? nil : wait_ms
    end

    T::Sig::WithoutRuntime.sig { params(estimate: T.untyped).void }
    def validate_estimate!(estimate)
      raise ArgumentError, 'expected estimate to be numeric' unless estimate.is_a?(Numeric)
      raise ArgumentError, 'expected estimate to be positive' unless estimate.positive?
      raise ArgumentError, 'expected estimate to not exceed capacity' if estimate > capacity
    end
  end
end
