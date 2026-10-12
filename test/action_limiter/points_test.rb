# typed: strict
# frozen_string_literal: true

require 'bigdecimal'
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

    it 'charges the default estimate when none is given' do
      limiter = Points.new(key, capacity: 10, restore_rate: 1, default_estimate: 4)

      assert_equal :result, limiter.within_limit { :result }
      assert_in_delta 6, balance, 0.5
    end

    it 'validates the default estimate at construction' do
      assert_raises(ArgumentError) { Points.new(key, capacity: 10, restore_rate: 1, default_estimate: 0) }
      assert_raises(ArgumentError) { Points.new(key, capacity: 10, restore_rate: 1, default_estimate: 11) }
    end

    it 'prefers an explicit estimate over the default' do
      limiter = Points.new(key, capacity: 10, restore_rate: 1, default_estimate: 4)
      limiter.within_limit(estimate: 2) { nil }

      assert_in_delta 8, balance, 0.5
    end

    it 'yields a handle' do
      limiter = Points.new(key, capacity: 100, restore_rate: 1)

      limiter.within_limit(estimate: 1) { |handle| assert_kind_of Points::Handle, handle }
    end

    it 'raises OverLimit with the time until enough points restore' do
      limiter = Points.new(key, capacity: 10, restore_rate: 10)
      limiter.within_limit(estimate: 10) { nil }

      error = assert_raises(OverLimit) { limiter.within_limit(estimate: 5) { nil } }

      assert_in_delta 0.5, error.retry_after, 0.05
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

    it 'keeps waiting when a refund may restore points before the retry time' do
      limiter = Points.new(key, capacity: 10, restore_rate: 0.001, wait_timeout: 1)
      holder = Thread.new do
        limiter.within_limit(estimate: 10) do |handle|
          sleep(0.3)
          handle.points_used(0)
        end
      end
      sleep(0.1)

      assert_equal :result, limiter.within_limit(estimate: 5) { :result }
      holder.join
    end

    it 'accepts a Rational estimate' do
      limiter = Points.new(key, capacity: 10, restore_rate: 0.001)

      assert_equal :result, limiter.within_limit(estimate: 5/2r) { :result }
      assert_in_delta 7.5, balance, 0.01
    end

    it 'accepts a BigDecimal actual cost' do
      limiter = Points.new(key, capacity: 10, restore_rate: 0.001)
      limiter.within_limit(estimate: 5) { |handle| handle.points_used(BigDecimal('1.5')) }

      assert_in_delta 8.5, balance, 0.01
    end

    it 'rejects non-finite actual costs without adjusting the balance or consuming the handle' do
      [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |actual|
        cleanup_keys(key)
        limiter = Points.new(key, capacity: 10, restore_rate: 1)

        limiter.within_limit(estimate: 5) do |handle|
          state = redis.hgetall(key)

          assert_raises(ArgumentError) { handle.points_used(actual) }
          assert_equal state, redis.hgetall(key)
          handle.points_used(0)
        end

        assert_in_delta 10, balance, 0.001
      end
    end

    it 'rejects non-finite adjustments without changing the balance' do
      limiter = Points.new(key, capacity: 10, restore_rate: 1)
      limiter.within_limit(estimate: 5) { nil }
      state = redis.hgetall(key)

      [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |delta|
        assert_raises(ArgumentError) { limiter.adjust(delta) }
      end

      assert_equal state, redis.hgetall(key)
    end

    it 'validates the estimate before touching Redis' do
      limiter = Points.new(key, capacity: 10, restore_rate: 1)

      assert_raises(ArgumentError) { limiter.within_limit { nil } }
      assert_raises(ArgumentError) { limiter.within_limit(estimate: 0) { nil } }
      assert_raises(ArgumentError) { limiter.within_limit(estimate: 11) { nil } }
      assert_raises(ArgumentError) { limiter.within_limit(estimate: 1, extra: true) { nil } }
      assert_equal 0, redis.exists(key)
    end

    it 'never moves the timestamp backwards when a caller clock lags' do
      t = now_ms
      acquire = lambda do |at, estimate|
        Integer(Points::ACQUIRE_SCRIPT.call(redis, keys: [key], argv: [at, 10, 10.0, estimate]))
      end

      acquire.call(t, 5)
      acquire.call(t - 500, 1)

      assert_operator redis.hget(key, 'updated_at_ms').to_i, :>=, t
      assert_operator acquire.call(t, 9), :>, 0
    end

    it 'keeps the key alive for the full refill from a stored timestamp ahead of the caller' do
      t = now_ms
      # A caller whose clock ran 10s ahead stored a full bucket
      redis.hset(key, 'points', '10', 'updated_at_ms', t + 10_000)

      assert_equal 0, Integer(Points::ACQUIRE_SCRIPT.call(redis, keys: [key], argv: [t, 10, 1.0, 10]))
      # Refill completes 10s after the stored timestamp, which is itself 10s ahead
      assert_operator redis.pttl(key), :>, 20_000
    end

    it 'keeps the key alive for the full refill after an adjustment behind the stored timestamp' do
      t = now_ms
      redis.hset(key, 'points', '5', 'updated_at_ms', t + 10_000)

      Points::ADJUST_SCRIPT.call(redis, keys: [key], argv: [t, 10, 1.0, -5])

      assert_operator redis.pttl(key), :>, 20_000
    end

    it 'validates its arguments' do
      assert_raises(ArgumentError) { Points.new(key, capacity: 0, restore_rate: 1) }
      assert_raises(ArgumentError) { Points.new(key, capacity: 1, restore_rate: 0) }
    end
  end
end
