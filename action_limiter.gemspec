# typed: true
# frozen_string_literal: true

require_relative 'lib/action_limiter/version'

Gem::Specification.new do |spec|
  spec.name        = 'action_limiter'
  spec.version     = ActionLimiter::VERSION
  spec.authors     = ['Minty Fresh']
  spec.email       = ['7896757+mintyfresh@users.noreply.github.com']
  spec.summary     = 'Redis-backed rate limiters for concurrent, windowed, bucketed, and points-based use cases.'
  spec.description = 'Redis-backed rate limiters supporting concurrent (semaphore), sliding-window, ' \
                     'multi-key sliding-window, fixed-interval bucket, and points-based strategies.'

  spec.required_ruby_version = '>= 3.4'

  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files         = Dir.glob(['lib/**/*.rb', 'lib/**/*.lua', 'README.md'], base: __dir__)
  spec.require_paths = ['lib']

  spec.add_dependency 'activesupport', '>= 8'
  spec.add_dependency 'redis'
  spec.add_dependency 'sorbet-runtime'
end
