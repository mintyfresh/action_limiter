# typed: true
# frozen_string_literal: true

require 'test_helper'
require 'graphql'

module ActionLimiter
  class GraphQLRateLimitsTest < TestCase
    class PingResolver < ::GraphQL::Schema::Resolver
      include ActionLimiter::GraphQL::RateLimits

      type String, null: false

      def resolve
        with_rate_limits('global', limit: 1, per: 10) { 'pong' }
      end
    end

    class QueryType < ::GraphQL::Schema::Object
      field :ping, resolver: PingResolver
    end

    class Schema < ::GraphQL::Schema
      query QueryType
    end

    before do
      cleanup_keys(rate_limit_key)
    end

    after do
      cleanup_keys(rate_limit_key)
    end

    def rate_limit_key
      "PingResolver:#{Digest::SHA256.hexdigest('global')}:rate_limit"
    end

    it 'resolves while under the limit' do
      result = Schema.execute('{ ping }')

      assert_equal 'pong', result.to_h.dig('data', 'ping')
    end

    it 'returns a RATE_LIMIT error once over the limit' do
      Schema.execute('{ ping }')
      result = Schema.execute('{ ping }')

      error = result.to_h['errors'].first

      assert_equal 'Rate limit exceeded', error['message']
      assert_equal 'RATE_LIMIT', error.dig('extensions', 'code')
    end
  end
end
