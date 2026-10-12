# typed: true
# frozen_string_literal: true

require 'test_helper'
require 'active_job'

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)

module ActionLimiter
  class AutomaticRetriesTest < TestCase
    class LimitedJob < ActiveJob::Base
      include ActionLimiter::AutomaticRetries

      def perform(retry_options = {})
        limiter = Window.new('test:limiter:job', limit: 1, duration: 1, retry_options:)
        raise OverLimit.new(limiter, retry_after: 2.0)
      end
    end

    class Reporter
      attr_reader :errors

      def initialize
        @errors = []
      end

      def report(error, **)
        @errors << error
      end
    end

    before do
      enqueued_jobs.clear
    end

    def enqueued_jobs
      ActiveJob::Base.queue_adapter.enqueued_jobs
    end

    it 'reschedules with retry_after plus linear backoff and jitter' do
      LimitedJob.new.perform_now

      delay = enqueued_jobs.last.fetch(:at) - Time.now.to_f
      assert_equal 1, enqueued_jobs.size
      assert_operator delay, :>=, 2 + 300 - 1
      assert_operator delay, :<=, 2 + 300 + 30 + 1
    end

    it 'honors the queue and priority retry options' do
      LimitedJob.new({ queue: 'slow', priority: 5 }).perform_now

      assert_equal 'slow', enqueued_jobs.last.fetch('queue_name')
      assert_equal 5, enqueued_jobs.last.fetch('priority')
    end

    it 're-raises once the default attempts are exhausted' do
      job = LimitedJob.new
      job.executions = ActionLimiter.default_over_limit_retry_attempts

      assert_raises(OverLimit) { job.perform_now }
      assert_empty enqueued_jobs
    end

    it 'honors a per-limiter attempts override' do
      assert_raises(OverLimit) { LimitedJob.new({ attempts: 1 }).perform_now }
    end

    it 'reports the error when asked to' do
      reporter = Reporter.new
      ActiveSupport.error_reporter.subscribe(reporter)

      LimitedJob.new({ report: true }).perform_now

      assert_equal 1, reporter.errors.size
      assert_kind_of OverLimit, reporter.errors.first
    ensure
      ActiveSupport.error_reporter.unsubscribe(reporter)
    end
  end
end
