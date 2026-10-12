# typed: strict
# frozen_string_literal: true

module ActionLimiter
  # The interface shared by every limiter, including +ActionLimiter::Unlimited+, so that any
  # limiter can stand in for any other:
  #
  #     limiter = current_user.admin? ? ActionLimiter::Unlimited.new : ERP_LIMIT
  #     limiter.within_limit { erp_client.call(...) }
  class Limiter
    extend T::Sig
    extend T::Helpers

    abstract!

    # Retry options specific to ActiveJob usage (see +ActionLimiter::AutomaticRetries+)
    sig { returns(T::Hash[Symbol, T.untyped]) }
    attr_reader :retry_options

    sig { params(retry_options: T::Hash[Symbol, T.untyped]).void }
    def initialize(retry_options: {})
      @retry_options = retry_options
    end

    # A human-readable name for the limited resource, used in error messages
    sig { abstract.returns(String) }
    def description; end

    # Run the block once the limit permits, yielding a limiter-specific handle (or nil).
    # Returns the block's result.
    sig do
      abstract
        .type_parameters(:Result)
        .params(options: T.untyped, block: T.proc.params(handle: T.untyped).returns(T.type_parameter(:Result)))
        .returns(T.type_parameter(:Result))
    end
    def within_limit(**options, &block); end
  end
end
