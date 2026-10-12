# typed: strict
# frozen_string_literal: true

module ActionLimiter
  class OverLimit < StandardError
    extend T::Sig

    # The limiter whose limit was exceeded
    sig { returns(Limiter) }
    attr_reader :limiter

    # The number of seconds (fractional) to wait until the next attempt
    sig { returns(Float) }
    attr_reader :retry_after

    sig { params(limiter: Limiter, retry_after: Float).void }
    def initialize(limiter, retry_after:)
      super("Rate limit exceeded for #{limiter.description}")
      @limiter = limiter
      @retry_after = retry_after
    end

    # Retry options specific to ActiveJob usage
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def retry_options
      limiter.retry_options
    end
  end
end
