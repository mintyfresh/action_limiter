# typed: strict
# frozen_string_literal: true

module ActionLimiter
  module GraphQL
    # Rate limits for GraphQL resolvers, backed by +ActionLimiter::MultiWindow+:
    #
    #     class CreateComment < GraphQL::Schema::Mutation
    #       include ActionLimiter::GraphQL::RateLimits
    #
    #       def resolve(...)
    #         with_rate_limits(context[:current_user].id.to_s, limit: 10, per: 1.minute) { ... }
    #       end
    #     end
    module RateLimits
      extend T::Sig
      extend T::Helpers

      requires_ancestor { ::GraphQL::Schema::Resolver }

      include Kernel

      sig do
        type_parameters(:Result)
          .params(
            additional_keys: String,
            limit: Integer,
            per: T.any(Integer, ActiveSupport::Duration),
            scope: String,
            block: T.proc.returns(T.type_parameter(:Result))
          )
          .returns(T.type_parameter(:Result))
      end
      def with_rate_limits(*additional_keys, limit:, per:, scope: default_rate_limits_scope, &block)
        keys = [*default_rate_limits_keys, *additional_keys].map do |key|
          "#{scope}:#{Digest::SHA256.hexdigest(key)}:rate_limit"
        end

        limiter = ActionLimiter::MultiWindow.new(
          keys,
          limit:,
          duration: per,
          wait_timeout: 0,
          redis: default_rate_limits_redis
        )

        limiter.within_limit { yield } # rubocop:disable Style/ExplicitBlockArgument
      rescue ActionLimiter::OverLimit => error
        handle_over_limit_error(error)
      end

    protected

      sig { returns(Redis) }
      def default_rate_limits_redis
        ActionLimiter.redis
      end

      sig { returns(T::Array[String]) }
      def default_rate_limits_keys
        []
      end

      sig { returns(String) }
      def default_rate_limits_scope
        T.cast(self.class, T.class_of(::GraphQL::Schema::Resolver)).graphql_name
      end

      sig { params(error: ::ActionLimiter::OverLimit).returns(T.untyped) }
      def handle_over_limit_error(error) # rubocop:disable Lint/UnusedMethodArgument
        raise ::GraphQL::ExecutionError.new(
          'Rate limit exceeded',
          extensions: { code: 'RATE_LIMIT' }
        )
      end
    end
  end
end
