# typed: strict
# frozen_string_literal: true

module ActionLimiter
  class Railtie < ::Rails::Railtie
    config.action_limiter = ::ActiveSupport::OrderedOptions.new

    initializer 'action_limiter.configure' do |app|
      app.config.action_limiter.each do |key, value|
        ActionLimiter.public_send(:"#{key}=", value)
      end
    end
  end
end
