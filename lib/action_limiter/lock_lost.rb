# typed: strict
# frozen_string_literal: true

module ActionLimiter
  # Raised when renewing a concurrency lock that has already been reclaimed, meaning the holder
  # has lost exclusivity and another caller may now hold its slot.
  class LockLost < StandardError
    extend T::Sig

    sig { returns(Limiter) }
    attr_reader :limiter

    sig { params(limiter: Limiter).void }
    def initialize(limiter)
      super("Lock lost for #{limiter.description}")
      @limiter = limiter
    end
  end
end
