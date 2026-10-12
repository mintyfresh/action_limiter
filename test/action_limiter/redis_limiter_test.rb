# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class RedisLimiterTest < TestCase
    # Replays a fixed sequence of acquisition results: nil admits, an Integer is ms to wait
    class FakeLimiter < RedisLimiter
      extend T::Sig

      sig do
        params(
          results: T::Array[T.nilable(Integer)],
          wait_timeout: T.any(Integer, ::ActiveSupport::Duration)
        ).void
      end
      def initialize(results, wait_timeout: 0)
        super(wait_timeout:, redis: ActionLimiter.redis, retry_options: { queue: 'slow' })
        @results = results
      end

      sig { override.returns(String) }
      def description
        'fake'
      end

      sig do
        override
          .type_parameters(:Result)
          .params(options: T.untyped, block: T.proc.params(handle: T.untyped).returns(T.type_parameter(:Result)))
          .returns(T.type_parameter(:Result))
      end
      def within_limit(**options, &block)
        reject_options!(options)
        wait_until_acquired { @results.shift }
        yield(nil)
      end
    end

    it 'returns the block result when acquired immediately' do
      assert_equal :result, FakeLimiter.new([nil]).within_limit { :result }
    end

    it 'sleeps for the reported retry time and tries again' do
      started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      assert_equal :result, FakeLimiter.new([50, nil], wait_timeout: 1).within_limit { :result }
      assert_operator ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at, :>=, 0.05
    end

    it 'raises OverLimit carrying the limiter and retry time once the deadline passes' do
      limiter = FakeLimiter.new([250])
      error = assert_raises(OverLimit) { limiter.within_limit { :result } }

      assert_same limiter, error.limiter
      assert_in_delta 0.25, error.retry_after
      assert_equal({ queue: 'slow' }, error.retry_options)
      assert_equal 'Rate limit exceeded for fake', error.message
    end

    it 'raises immediately when the retry time exceeds the remaining wait' do
      started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      error = assert_raises(OverLimit) { FakeLimiter.new([5000, nil], wait_timeout: 1).within_limit { :result } }

      assert_in_delta 5.0, error.retry_after
      assert_operator ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at, :<, 0.1
    end

    it 'waits out the deadline when the wait timeout is greedy' do
      limiter = FakeLimiter.new([5000, nil], wait_timeout: 1)
      limiter.define_singleton_method(:greedy_wait_timeout?) { true }
      started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      assert_equal :result, limiter.within_limit { :result }
      assert_operator ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at, :>=, 1
    end

    it 'instruments acquire with the time waited' do
      events = capture_events('acquire.action_limiter') do
        FakeLimiter.new([20, nil], wait_timeout: 1).within_limit { nil }
      end

      assert_equal 1, events.size
      assert_kind_of FakeLimiter, events.first&.payload&.fetch(:limiter)
      assert_operator T.must(events.first).payload.fetch(:waited), :>=, 0.02
    end

    it 'instruments over_limit with the error' do
      error = T.let(nil, T.nilable(OverLimit))
      events = capture_events('over_limit.action_limiter') do
        error = assert_raises(OverLimit) { FakeLimiter.new([100]).within_limit { nil } }
      end

      assert_equal 1, events.size
      assert_same error, T.must(events.first).payload.fetch(:error)
    end

    it 'rejects unknown within_limit options' do
      error = assert_raises(ArgumentError) { FakeLimiter.new([nil]).within_limit(estimate: 5) { nil } }
      assert_match(/estimate/, error.message)
    end

    it 'rejects a negative wait_timeout' do
      assert_raises(ArgumentError) { FakeLimiter.new([nil], wait_timeout: -1) }
    end

    it 'rejects a sub-second wait_timeout instead of truncating it' do
      error = assert_raises(ArgumentError) { FakeLimiter.new([nil], wait_timeout: 0.5.seconds) }
      assert_equal 'expected wait_timeout to be a whole number of seconds', error.message
    end

    it 'accepts a whole-second Duration wait_timeout' do
      assert_equal 2, FakeLimiter.new([nil], wait_timeout: 2.seconds).wait_timeout
    end

    it 'builds a LockLost error naming the limiter' do
      limiter = FakeLimiter.new([nil])
      error = LockLost.new(limiter)

      assert_same limiter, error.limiter
      assert_equal 'Lock lost for fake', error.message
    end
  end
end
