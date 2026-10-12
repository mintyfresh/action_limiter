# typed: strict
# frozen_string_literal: true

module ActionLimiter
  module ActionController
    autoload :RateLimits, 'action_limiter/action_controller/rate_limits'
  end
end
