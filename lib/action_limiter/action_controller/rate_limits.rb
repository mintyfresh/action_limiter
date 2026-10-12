# typed: strict
# frozen_string_literal: true

require 'action_controller'

module ActionLimiter
  module ActionController
    # Enforces rate limits on controller actions with any ActionLimiter limiter:
    #
    #     class MessagesController < ApplicationController
    #       include ActionLimiter::ActionController::RateLimits
    #
    #       rate_limit only: :create do
    #         ActionLimiter::Window.new("messages:#{current_user.id}", limit: 20, duration: 1.minute)
    #       end
    #
    #       rate_limit only: :search, with: SEARCH_LIMIT
    #       rate_limit only: :stream, with: :stream_limiter
    #     end
    #
    # Over the limit, +handle_over_limit_error+ raises +ActionController::TooManyRequests+ whose
    # +cause+ is the +ActionLimiter::OverLimit+.
    module RateLimits
      extend T::Sig
      extend T::Helpers
      extend ActiveSupport::Concern

      requires_ancestor { ::ActionController::Metal }

      include Kernel

      module ClassMethods
        extend T::Sig
        extend T::Generic

        include Kernel

        has_attached_class!(:out)

        sig do
          params(
            with: T.nilable(T.any(ActionLimiter::Limiter, Symbol)),
            filters: T.untyped,
            block: T.nilable(T.proc.bind(T.attached_class).returns(ActionLimiter::Limiter))
          ).void
        end
        def rate_limit(with: nil, **filters, &block)
          raise ArgumentError, 'expected with: or a block, not both' if with && block
          raise ArgumentError, 'expected with: or a block' if with.nil? && block.nil?

          source = with || block
          T.bind(self, T.any(T.class_of(::ActionController::Base), T.class_of(::ActionController::API)))

          around_action(**filters) do |controller, action|
            controller.send(:within_rate_limit, source, &action)
          end
        end
      end

      mixes_in_class_methods ClassMethods

    protected

      sig { params(error: ActionLimiter::OverLimit).void }
      def handle_over_limit_error(error)
        raise ::ActionController::TooManyRequests, error.message
      end

    private

      sig { params(source: T.any(ActionLimiter::Limiter, Symbol, T.proc.returns(ActionLimiter::Limiter)), action: T.proc.void).void }
      def within_rate_limit(source, &action)
        acquired = T.let(false, T::Boolean)

        resolve_rate_limiter(source).within_limit do
          acquired = true
          yield
        end
      rescue ActionLimiter::OverLimit => error
        raise if acquired

        handle_over_limit_error(error)
      end

      sig { params(source: T.any(ActionLimiter::Limiter, Symbol, T.proc.returns(ActionLimiter::Limiter))).returns(ActionLimiter::Limiter) }
      def resolve_rate_limiter(source)
        case source
        when ActionLimiter::Limiter then source
        when Symbol then send(source)
        else instance_exec(&source)
        end
      end
    end
  end
end
