# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class UnlimitedTest < TestCase
    it 'returns the block result' do
      assert_equal :result, Unlimited.new.within_limit { :result }
    end

    it 'yields a handle that stands in for leases and points handles' do
      Unlimited.new.within_limit(estimate: 500) do |handle|
        handle.renew
        handle.points_used(1_000)
        assert handle.held?
      end
    end

    it 'is a Limiter' do
      assert_kind_of Limiter, Unlimited.new
      assert_empty Unlimited.new.retry_options
    end

    it 'never touches Redis' do
      ActionLimiter.redis = 'redis://localhost:1/0'
      assert_equal :result, Unlimited.new.within_limit { :result }
    ensure
      ActionLimiter.redis = REDIS_URL
    end

    it 'emits no instrumentation' do
      events = capture_events('acquire.action_limiter') { Unlimited.new.within_limit { nil } }
      assert_empty events
    end
  end
end
