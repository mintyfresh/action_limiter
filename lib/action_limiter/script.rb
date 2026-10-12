# typed: strict
# frozen_string_literal: true

module ActionLimiter
  # A Lua script loaded from +lib/action_limiter/scripts+, run via +EVALSHA+.
  class Script
    extend T::Sig

    DIRECTORY = T.let(File.expand_path('scripts', __dir__), String)

    sig { returns(String) }
    attr_reader :source

    sig { returns(String) }
    attr_reader :sha

    sig { params(name: String).void }
    def initialize(name)
      @source = T.let(File.read(File.join(DIRECTORY, "#{name}.lua")).freeze, String)
      @sha = T.let(Digest::SHA1.hexdigest(@source), String)
    end

    T::Sig::WithoutRuntime.sig do
      params(redis: Connection, keys: T::Array[String], argv: T::Array[T.any(String, Numeric)]).returns(T.untyped)
    end
    def call(redis, keys:, argv:)
      redis.with do |connection|
        connection.evalsha(sha, keys:, argv:)
      rescue Redis::NoScriptError, RedisClient::NoScriptError
        # Script might've been evicted from the script cache, reload it
        connection.script(:load, source)
        connection.evalsha(sha, keys:, argv:)
      end
    end
  end
end
