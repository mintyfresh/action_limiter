# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class PointsTest < TestCase
    before do
      @key = T.let("test:limiter:points:#{::SecureRandom.hex(8)}", String)
    end

    after do
      cleanup_keys(key)
    end

    sig { returns(String) }
    attr_reader :key

    sig { returns(Float) }
    def balance
      redis.hget(key, 'points').to_f
    end

    it 'deducts the estimate and returns the block result' do
      limiter = Points.new(key, capacity: 100, restore_rate: 1)

      assert_equal :result, limiter.within_limit(estimate: 30) { :result }
      assert_in_delta 70, balance, 0.5
    end

    it 'yields a handle' do
      limiter = Points.new(key, capacity: 100, restore_rate: 1)
      limiter.within_limit(estimate: 1) { |handle| assert_kind_of Points::Handle, handle }
    end

    it 'raises OverLimit with the time until enough points restore' do
      limiter = Points.new(key, capacity: 10, restore_rate: 10)
      limiter.within_limit(estimate: 10) { nil }

      error = assert_raises(OverLimit) { limiter.within_limit(estimate: 5) { nil } }

      assert_same limiter, error.limiter
      assert_in_delta 0.5, error.retry_after, 0.05
      assert_match(/#{::Regexp.escape(key)}/, error.message)
    end

    it 'computes waits correctly for a fractional restore rate' do
      limiter = Points.new(key, capacity: 2, restore_rate: 0.5)
      limiter.within_limit(estimate: 2) { nil }

      error = assert_raises(OverLimit) { limiter.within_limit(estimate: 1) { nil } }
      assert_in_delta 2.0, error.retry_after, 0.05
      assert_operator redis.pttl(key), :>, 3_000
    end

    it 'waits for points to restore within wait_timeout' do
      limiter = Points.new(key, capacity: 10, restore_rate: 20, wait_timeout: 1)
      limiter.within_limit(estimate: 10) { nil }
      assert_equal :result, limiter.within_limit(estimate: 5) { :result }
    end

    it 'refunds an overestimate' do
      limiter = Points.new(key, capacity: 100, restore_rate: 1)
      limiter.within_limit(estimate: 50) { |handle| handle.points_used(20) }
      assert_in_delta 80, balance, 0.5
    end

    it 'caps refunds at capacity' do
      # 50 left after the estimate, +60 restored during the block, +50 refunded: capped at 100
      limiter = Points.new(key, capacity: 100, restore_rate: 100)

      limiter.within_limit(estimate: 50) do |handle|
        sleep(0.6)
        handle.points_used(0)
      end

      assert_in_delta 100, balance, 0.001
    end

    it 'debits an underestimate into debt that delays the next caller' do
      limiter = Points.new(key, capacity: 10, restore_rate: 10)
      limiter.within_limit(estimate: 10) { |handle| handle.points_used(15) }

      assert_in_delta(-5, balance, 0.5)
      error = assert_raises(OverLimit) { limiter.within_limit(estimate: 1) { nil } }
      assert_in_delta 0.6, error.retry_after, 0.06
    end

    it 'keeps the estimate when the block raises' do
      limiter = Points.new(key, capacity: 100, restore_rate: 1)
      assert_raises(RuntimeError) { limiter.within_limit(estimate: 40) { raise 'boom' } }
      assert_in_delta 60, balance, 0.5
    end

    it 'rejects a second points_used call' do
      limiter = Points.new(key, capacity: 100, restore_rate: 1)

      limiter.within_limit(estimate: 10) do |handle|
        handle.points_used(5)
        assert_raises(ArgumentError) { handle.points_used(5) }
      end
    end

    it 'validates the estimate before touching Redis' do
      limiter = Points.new(key, capacity: 10, restore_rate: 1)

      assert_raises(ArgumentError) { limiter.within_limit { nil } }
      assert_raises(ArgumentError) { limiter.within_limit(estimate: 0) { nil } }
      assert_raises(ArgumentError) { limiter.within_limit(estimate: -1) { nil } }
      assert_raises(ArgumentError) { limiter.within_limit(estimate: 11) { nil } }
      assert_raises(ArgumentError) { limiter.within_limit(estimate: 1, extra: true) { nil } }
      assert_equal 0, redis.exists(key)
    end

    it 'never moves the timestamp backwards when a caller clock lags' do
      t = now_ms
      acquire = lambda do |at, estimate|
        Integer(Points::ACQUIRE_SCRIPT.call(redis, keys: [key], argv: [at, 10, 10.0, estimate]))
      end

      assert_equal 0, acquire.call(t, 5)
      assert_equal 0, acquire.call(t - 500, 1)
      assert_operator redis.hget(key, 'updated_at_ms').to_i, :>=, t
      assert_operator acquire.call(t, 9), :>, 0
    end

    it 'validates its arguments' do
      assert_raises(ArgumentError) { Points.new(key, capacity: 0, restore_rate: 1) }
      assert_raises(ArgumentError) { Points.new(key, capacity: 1, restore_rate: 0) }
      assert_raises(ArgumentError) { Points.new(key, capacity: 1, restore_rate: 1, wait_timeout: -1) }
    end
  end
end
