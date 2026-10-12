# ActionLimiter

Redis-backed rate limiters for Ruby: concurrency, sliding windows, fixed buckets, and points.

## Installation

```ruby
gem 'action_limiter'
```

## Requirements

Ruby 3.4+ and Redis 6.0+ (Concurrent uses fractional BRPOP timeouts, which need Redis 6.0).

## Configuration

```ruby
ActionLimiter.redis = ENV.fetch('REDIS_URL')     # a URL, a Redis instance, or a Hash of Redis.new options
ActionLimiter.default_wait_timeout = 0           # seconds to wait for capacity before raising
ActionLimiter.default_concurrent_lock_ttl = 10   # extra seconds Concurrent keys outlive their locks
ActionLimiter.default_over_limit_retry_attempts = 20
```

Every limiter also accepts `redis:` (a Redis instance), `wait_timeout:`, and `retry_options:` keywords. Limiters are
thread-safe; create global ones once at boot and parametric ones (per user, per account) on demand.

When a limit can't be met within `wait_timeout`, `ActionLimiter::OverLimit` is raised. It
exposes `limiter`, `retry_after` (Float seconds), and `retry_options`.

## Limiters

### Window: at most N per rolling duration

```ruby
ERP = ActionLimiter::Window.new('erp', limit: 50, duration: 30.seconds, wait_timeout: 5)
ERP.within_limit { erp_client.call }
```

### MultiWindow: one action, several windows, checked atomically

```ruby
limiter = ActionLimiter::MultiWindow.new(["user:#{user.id}", 'provider'], limit: 10, duration: 1.minute)
limiter.within_limit { provider_client.call }
```

### Bucket: at most N per clock-aligned interval

```ruby
PAYMENTS = ActionLimiter::Bucket.new('payment-api', limit: 30, interval: 1.second, wait_timeout: 5)
PAYMENTS.within_limit { payment_client.call }
```

### Concurrent: at most N at once

```ruby
STREAMS = ActionLimiter::Concurrent.new('streams', limit: 50, lock_timeout: 30, wait_timeout: 5)

STREAMS.within_limit do |lease|
  stream.each_chunk do |chunk|
    write(chunk)
    lease.renew # extends the lock; raises ActionLimiter::LockLost if it was reclaimed
  end
end
```

Concurrent also accepts `ttl:` (defaults to `default_concurrent_lock_ttl`). Locks held past
`lock_timeout` without renewal may be reclaimed by other callers. A limit of 1 makes a
distributed mutex.

### Points: variable-cost requests

```ruby
SHOPIFY = ActionLimiter::Points.new('shopify', capacity: 1000, restore_rate: 50, wait_timeout: 5)

SHOPIFY.within_limit(estimate: 200) do |handle|
  response = client.query(query)
  handle.points_used(response.cost.actual)
end
```

Overestimates are refunded (capped at `capacity`). Underestimates go into debt that delays later
callers. `points_used` may be called once per call. If it is never called, the estimate stands.

### Unlimited: a null object

```ruby
limiter = current_user.admin? ? ActionLimiter::Unlimited.new : ERP
```

It never touches Redis, accepts any `within_limit` options, and yields a handle that responds to
`renew`, `points_used`, and `held?`.

## ActiveJob

```ruby
class ApplicationJob < ActiveJob::Base
  include ActionLimiter::AutomaticRetries
end
```

`OverLimit` is rescued, and the job is rescheduled after
`retry_after + executions * 5.minutes + jitter`, up to 20 times. Override
`calculate_over_limit_retry_delay(error)` or `over_limit_retry_attempts` to change this. Set
`retry_options` on a limiter for per-limiter `attempts:` (or `:unlimited`), `report:`, `queue:`,
and `priority:`.

## GraphQL

```ruby
class CreateComment < GraphQL::Schema::Mutation
  include ActionLimiter::GraphQL::RateLimits

  def resolve(body:)
    with_rate_limits(context[:current_user].id.to_s, limit: 10, per: 1.minute) { create(body) }
  end
end
```

Over the limit, the field returns a `GraphQL::ExecutionError` with `extensions: { code: 'RATE_LIMIT' }`.

## Instrumentation

| Event | Payload |
|---|---|
| `acquire.action_limiter` | `limiter`, `waited` (seconds) |
| `over_limit.action_limiter` | `limiter`, `error` |
| `release_failed.action_limiter` | `limiter`, `error` (Concurrent only; the lock expires via `lock_timeout`) |
| `lock_lost.action_limiter` | `limiter` (Concurrent only) |

## Clocks

Limiters use the calling process's wall clock. Keep machines in sync with NTP. Clock skew between
hosts beyond a few seconds can briefly over- or under-admit Concurrent waiters, so keep hosts
NTP-synced.

## Development

```sh
mise install
mise exec -- redis-server --daemonize yes
bundle install
bundle exec rake          # tests and RuboCop
bundle exec rake sorbet   # srb tc
```

Tests use Redis db 15; set `REDIS_URL` to point elsewhere.
