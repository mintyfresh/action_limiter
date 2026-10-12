# typed: strict
# frozen_string_literal: true

module ActionLimiter
  # A limiter that never limits and never touches Redis. Stands in for any other limiter, for
  # conditional limiting or in tests:
  #
  #     limiter = current_user.admin? ? ActionLimiter::Unlimited.new : ERP_LIMIT
  class Unlimited < Limiter
    extend T::Sig

    # Responds to every limiter handle's methods as no-ops
    class Handle
      extend T::Sig

      sig { void }
      def renew; end

      sig { params(_actual: Numeric).void }
      def points_used(_actual); end

      sig { returns(T::Boolean) }
      def held?
        true
      end
    end

    HANDLE = Handle.new.freeze

    sig { override.returns(String) }
    def description
      'unlimited'
    end

    # Accepts and ignores every option (e.g. +estimate:+) so it can stand in at any call site
    T::Sig::WithoutRuntime.sig do
      override
        .type_parameters(:Result)
        .params(_options: T.untyped, block: T.proc.params(handle: T.untyped).returns(T.type_parameter(:Result)))
        .returns(T.type_parameter(:Result))
    end
    def within_limit(**_options, &block)
      yield(HANDLE)
    end
  end
end
