# typed: true
# frozen_string_literal: true

require 'test_helper'
require 'action_controller'

module ActionLimiter
  class ActionControllerRateLimitsTest < TestCase
    PREFIX = 'test:limiter:controller'

    class LimitedController < ::ActionController::API
      include ActionLimiter::ActionController::RateLimits

      STATIC = ActionLimiter::Window.new("#{PREFIX}:static", limit: 1, duration: 10)
      NESTED = ActionLimiter::Window.new("#{PREFIX}:nested", limit: 10, duration: 10)

      rate_limit only: :block_limited do
        ActionLimiter::Window.new("#{PREFIX}:block:#{params[:user]}", limit: 1, duration: 10)
      end

      rate_limit only: :static_limited, with: STATIC
      rate_limit only: :method_limited, with: :method_limiter
      rate_limit only: :nested, with: NESTED

      rate_limit only: :stream do
        ActionLimiter::Concurrent.new("#{PREFIX}:stream", limit: 1, lock_timeout: 10)
      end

      rate_limit only: :search do
        @points = ActionLimiter::Points.new("#{PREFIX}:points", capacity: 5, restore_rate: 1, default_estimate: 5)
      end

      def block_limited = render(plain: 'ok')
      def static_limited = render(plain: 'ok')
      def method_limited = render(plain: 'ok')
      def open = render(plain: 'ok')

      def nested
        inner = ActionLimiter::Window.new("#{PREFIX}:inner", limit: 1, duration: 10)
        raise ActionLimiter::OverLimit.new(inner, retry_after: 1.0)
      end

      def stream
        sleep(0.3)
        render(plain: 'ok')
      end

      def search = render(plain: @points.capacity.to_s)

    private

      def method_limiter
        ActionLimiter::Window.new("#{PREFIX}:method", limit: 1, duration: 10)
      end
    end

    class InheritedController < LimitedController; end

    class ExceptController < ::ActionController::API
      include ActionLimiter::ActionController::RateLimits

      rate_limit except: :open do
        ActionLimiter::Window.new("#{PREFIX}:except", limit: 1, duration: 10)
      end

      def limited = render(plain: 'ok')
      def open = render(plain: 'ok')
    end

    class CustomHandlerController < ::ActionController::API
      include ActionLimiter::ActionController::RateLimits

      rate_limit do
        ActionLimiter::Window.new("#{PREFIX}:custom", limit: 1, duration: 10)
      end

      def limited = render(plain: 'ok')

    protected

      def handle_over_limit_error(error)
        render(plain: error.message, status: :too_many_requests)
      end
    end

    class MetalController < ::ActionController::Metal
      include ::AbstractController::Callbacks
      include ActionLimiter::ActionController::RateLimits

      rate_limit do
        ActionLimiter::Window.new("#{PREFIX}:metal", limit: 1, duration: 10)
      end

      def limited
        self.response_body = 'ok'
      end
    end

    class DeclarationController < ::ActionController::API
      include ActionLimiter::ActionController::RateLimits
    end

    before do
      cleanup_pattern("#{PREFIX}:*")
    end

    after do
      cleanup_pattern("#{PREFIX}:*")
    end

    def dispatch(controller, action, query = {})
      controller.action(action).call(Rack::MockRequest.env_for("/?#{query.to_query}"))
    end

    it 'admits a request under a block-built limit' do
      status, = dispatch(LimitedController, :block_limited, user: 'a')

      assert_equal 200, status
    end

    it 'raises TooManyRequests caused by OverLimit once over the limit' do
      dispatch(LimitedController, :block_limited, user: 'a')

      error = assert_raises(::ActionController::TooManyRequests) do
        dispatch(LimitedController, :block_limited, user: 'a')
      end
      assert_kind_of ActionLimiter::OverLimit, error.cause
    end

    it 'evaluates the block per request' do
      dispatch(LimitedController, :block_limited, user: 'a')
      status, = dispatch(LimitedController, :block_limited, user: 'b')

      assert_equal 200, status
    end

    it 'enforces a limiter instance given as with:' do
      dispatch(LimitedController, :static_limited)

      assert_raises(::ActionController::TooManyRequests) { dispatch(LimitedController, :static_limited) }
    end

    it 'enforces a limiter returned by a private method named in with:' do
      dispatch(LimitedController, :method_limited)

      assert_raises(::ActionController::TooManyRequests) { dispatch(LimitedController, :method_limited) }
    end

    it 'holds a concurrent slot for the whole action' do
      holder = Thread.new { dispatch(LimitedController, :stream) }
      sleep(0.1)

      assert_raises(::ActionController::TooManyRequests) { dispatch(LimitedController, :stream) }
      assert_equal 200, holder.value.first
    end

    it 'charges a Points default estimate and exposes the limiter to the action' do
      _, _, body = dispatch(LimitedController, :search)

      assert_equal '5', body.body
      assert_raises(::ActionController::TooManyRequests) { dispatch(LimitedController, :search) }
    end

    it 'lets an OverLimit raised inside the action propagate unchanged' do
      error = assert_raises(ActionLimiter::OverLimit) { dispatch(LimitedController, :nested) }

      assert_equal "#{PREFIX}:inner", error.limiter.description
    end

    it 'leaves actions outside only: unlimited' do
      2.times { dispatch(LimitedController, :open) }
      status, = dispatch(LimitedController, :open)

      assert_equal 200, status
    end

    it 'leaves actions in except: unlimited' do
      dispatch(ExceptController, :limited)

      assert_raises(::ActionController::TooManyRequests) { dispatch(ExceptController, :limited) }
      assert_equal 200, dispatch(ExceptController, :open).first
    end

    it 'applies inherited limits to subclasses' do
      dispatch(InheritedController, :static_limited)

      assert_raises(::ActionController::TooManyRequests) { dispatch(InheritedController, :static_limited) }
    end

    it 'uses an overridden handle_over_limit_error' do
      dispatch(CustomHandlerController, :limited)
      status, _, body = dispatch(CustomHandlerController, :limited)

      assert_equal 429, status
      assert_equal "Rate limit exceeded for #{PREFIX}:custom", body.body
    end

    it 'limits a Metal controller that includes callbacks' do
      dispatch(MetalController, :limited)

      assert_raises(::ActionController::TooManyRequests) { dispatch(MetalController, :limited) }
    end

    it 'rejects invalid declarations' do
      limiter = ActionLimiter::Unlimited.new

      assert_raises(ArgumentError) { DeclarationController.rate_limit(with: limiter) { limiter } }
      assert_raises(ArgumentError) { DeclarationController.rate_limit }
      assert_raises(TypeError) { DeclarationController.rate_limit(with: T.unsafe('limiter')) }
    end
  end
end
