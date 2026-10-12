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
            routing: T.nilable(String),
            transform: KeyTransform,
            block: T.proc.returns(T.type_parameter(:Result))
          )
          .returns(T.type_parameter(:Result))
      end
      def with_rate_limits( # rubocop:disable Metrics/ParameterLists
        *additional_keys,
        limit:,
        per:,
        scope: default_rate_limiter_scope,
        routing: default_rate_limiter_routing,
        transform: default_rate_limiter_transform,
        &block
      )
        limiter = rate_limiter(*T.unsafe(additional_keys), limit:, per:, scope:, routing:, transform:)
        limiter.within_limit { yield } # rubocop:disable Style/ExplicitBlockArgument
      rescue ActionLimiter::OverLimit => error
        handle_over_limit_error(error)
      end

    protected

      sig do
        overridable
          .params(
            additional_keys: String,
            limit: Integer,
            per: T.any(Integer, ActiveSupport::Duration),
            scope: String,
            routing: T.nilable(String),
            transform: KeyTransform
          )
          .returns(Limiter)
      end
      def rate_limiter(*additional_keys, limit:, per:, scope:, routing:, transform:) # rubocop:disable Metrics/ParameterLists
        keys = [*default_rate_limiter_keys, *additional_keys].map { |key| "#{scope}:#{key}:rate_limit" }

        MultiWindow.new(
          keys,
          limit:,
          duration: per,
          wait_timeout: 0,
          redis: default_rate_limiter_redis,
          routing:,
          transform:
        )
      end

      sig { returns(Connection) }
      def default_rate_limiter_redis
        ActionLimiter.redis
      end

      sig { returns(T::Array[String]) }
      def default_rate_limiter_keys
        []
      end

      sig { returns(String) }
      def default_rate_limiter_scope
        T.cast(self.class, T.class_of(::GraphQL::Schema::Resolver)).graphql_name
      end

      sig { returns(T.nilable(String)) }
      def default_rate_limiter_routing
        default_rate_limiter_scope
      end

      sig { returns(KeyTransform) }
      def default_rate_limiter_transform
        :sha256
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
