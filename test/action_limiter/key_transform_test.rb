# typed: strict
# frozen_string_literal: true

require 'test_helper'

module ActionLimiter
  class KeyTransformTest < TestCase
    before do
      @key = T.let("test:limiter:transform:#{::SecureRandom.hex(8)}", String)
      @written = T.let([], T::Array[String])
    end

    after do
      @written.each { |prefix| cleanup_pattern("*#{prefix}*") }
    end

    sig { returns(String) }
    attr_reader :key

    sig { params(prefix: String).returns(String) }
    def track(prefix)
      @written << prefix
      prefix
    end

    sig { params(name: String, value: String).returns(String) }
    def hexdigest(name, value)
      track(::OpenSSL::Digest.new(name).hexdigest(value))
    end

    it 'stores the digest named by a Symbol instead of the raw key' do
      limiter = Window.new(key, limit: 1, duration: 10, transform: :sha256)
      limiter.within_limit { nil }

      assert_equal 1, redis.exists(hexdigest('SHA256', key))
      assert_equal 0, redis.exists(track(key))
      assert_equal key, limiter.description
    end

    it 'stores the digest named by a String' do
      Window.new(key, limit: 1, duration: 10, transform: 'sha512').within_limit { nil }

      assert_equal 1, redis.exists(hexdigest('SHA512', key))
    end

    it 'stores the digest of an OpenSSL::Digest instance' do
      Window.new(key, limit: 1, duration: 10, transform: ::OpenSSL::Digest.new('SHA256')).within_limit { nil }

      assert_equal 1, redis.exists(hexdigest('SHA256', key))
    end

    it 'stores the result of a Proc' do
      Window.new(key, limit: 1, duration: 10, transform: -> (value) { "#{value}:custom" }).within_limit { nil }

      assert_equal 1, redis.exists(track("#{key}:custom"))
    end

    it 'transforms the routing hash tag along with the keys' do
      routing = "#{key}:routing"
      MultiWindow.new([key], limit: 1, duration: 10, routing:, transform: :sha256).within_limit { nil }

      assert_equal 1, redis.exists("{#{hexdigest('SHA256', routing)}}#{hexdigest('SHA256', key)}")
      assert_empty redis.keys("*#{track(routing)}*")
    end

    it 'stores the raw key without a transform' do
      Window.new(key, limit: 1, duration: 10).within_limit { nil }

      assert_equal 1, redis.exists(track(key))
    end

    it 'rejects an unknown digest name at construction' do
      assert_raises(::OpenSSL::Digest::DigestError) { Window.new(key, limit: 1, duration: 10, transform: :nope) }
    end

    it 'applies the transform to every Redis-backed limiter' do
      limiters = {
        'window'       => -> (k) { Window.new(k, limit: 1, duration: 10, transform: :sha256) },
        'multi_window' => -> (k) { MultiWindow.new([k], limit: 1, duration: 10, transform: :sha256) },
        'bucket'       => -> (k) { Bucket.new(k, limit: 1, interval: 60, transform: :sha256) },
        'multi_bucket' => -> (k) { MultiBucket.new([k], limit: 1, interval: 60, transform: :sha256) },
        'concurrent'   => -> (k) { Concurrent.new(k, limit: 1, lock_timeout: 10, transform: :sha256) },
        'points'       => lambda { |k|
          Points.new(k, capacity: 1, restore_rate: 1, default_estimate: 1, transform: :sha256)
        },
      }

      limiters.each do |name, build|
        limiter_key = "#{key}:#{name}"
        build.call(limiter_key).within_limit { nil }

        refute_empty redis.keys("*#{hexdigest('SHA256', limiter_key)}*"), "#{name} did not write the digest"
        assert_empty redis.keys("*#{track(limiter_key)}*"), "#{name} wrote the raw key"
      end
    end
  end
end
