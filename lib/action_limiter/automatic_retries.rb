# typed: strict
# frozen_string_literal: true

require 'active_job/base'

module ActionLimiter
  # Provides automatic retry handling for ActiveJob jobs that encounter
  # +ActionLimiter::OverLimit+ errors.
  #
  # Include this module in your base job class to automatically rescue
  # +OverLimit+ errors and retry the job with an appropriate delay.
  #
  #     class ApplicationJob < ActiveJob::Base
  #       include ActionLimiter::AutomaticRetries
  #     end
  #
  # == Configuration
  #
  # Override +over_limit_retry_attempts+ to change the maximum number of
  # retry attempts (default: 20). Override +calculate_over_limit_retry_delay+
  # to customize the backoff strategy.
  #
  # Per-limiter retry options can also be set via the +retry_options+ hash
  # on any limiter instance:
  #
  # * +:attempts+ — override the max attempts for this limiter
  # * +:report+ — report the error to +ActiveSupport.error_reporter+
  # * +:queue+ — retry on a different queue
  # * +:priority+ — retry with a different priority
  module AutomaticRetries
    extend T::Sig
    extend T::Helpers
    extend ActiveSupport::Concern

    requires_ancestor { ActiveJob::Base }

    included do
      T.bind(self, T.class_of(ActiveJob::Base))
      rescue_from ActionLimiter::OverLimit, with: :retry_on_over_limit
    end

    module ClassMethods
      extend T::Sig

      sig { returns(Integer) }
      def default_over_limit_retry_attempts
        @default_over_limit_retry_attempts ||= T.let(
          ActionLimiter.default_over_limit_retry_attempts,
          T.nilable(Integer)
        )
      end

      sig { params(value: Integer).void }
      def default_over_limit_retry_attempts=(value)
        @default_over_limit_retry_attempts = value
      end
    end

    mixes_in_class_methods ClassMethods

  protected

    sig { params(error: ActionLimiter::OverLimit).void }
    def retry_on_over_limit(error)
      T.bind(self, T.all(ActiveJob::Base, AutomaticRetries))
      attempts = error.retry_options[:attempts] || over_limit_retry_attempts

      if attempts == :unlimited || executions < attempts
        ActiveSupport.error_reporter.report(error, source: 'application.active_job') if error.retry_options[:report]
        retry_job(wait: calculate_over_limit_retry_delay(error), error:, **error.retry_options.slice(:queue, :priority))
      else
        instrument(:retry_stopped, error:)
        run_after_discard_procs(error)
        raise error
      end
    end

    sig { overridable.params(error: ActionLimiter::OverLimit).returns(T.any(Numeric, ActiveSupport::Duration)) }
    def calculate_over_limit_retry_delay(error)
      T.bind(self, T.all(ActiveJob::Base, AutomaticRetries))
      error.retry_after +
        (executions * 5.minutes) +
        (Kernel.rand(0.0..executions.to_f) * 30.seconds)
    end

    sig { overridable.returns(T.any(Integer, Symbol)) }
    def over_limit_retry_attempts
      T.bind(self, T.all(ActiveJob::Base, AutomaticRetries))
      T.cast(self.class, ClassMethods).default_over_limit_retry_attempts
    end
  end
end
