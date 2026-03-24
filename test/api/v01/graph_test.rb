# frozen_string_literal: true

require './test/test_helper'
require './test/api/v01/helpers/request_helper'

module Api
  module V01
    class GraphTest < Minitest::Test
      include Rack::Test::Methods
      include TestHelper

      def app
        Api::Root
      end

      def setup
        skip 'vrp_delaunay binary not built (rake ext:vrp_delaunay)' unless
          File.executable?(VrpGraph::DelaunayAdapter::BINARY_PATH)
      end

      def test_get_graph_returns_full_structure
        post '/0.1/vrp/graph',
             { api_key: 'demo', vrp: VRP.toy }.to_json,
             'CONTENT_TYPE' => 'application/json'

        assert_equal 200, last_response.status, last_response.body
        data = JSON.parse(last_response.body)
        assert data['nodes'].is_a?(Hash)
        assert data['edges'].is_a?(Array)
        assert data['incompatibilities'].is_a?(Array)
        assert data['knn_neighbors'].is_a?(Hash)
        assert data['metadata'].is_a?(Hash)
      end

      def test_get_graph_geojson_format
        post '/0.1/vrp/graph',
             { api_key: 'demo', vrp: VRP.toy, format: 'geojson' }.to_json,
             'CONTENT_TYPE' => 'application/json'

        assert_equal 200, last_response.status, last_response.body
        data = JSON.parse(last_response.body)
        assert_equal 'FeatureCollection', data['type']
        assert data['features'].is_a?(Array)
      end

      def test_get_graph_invalid_vrp_returns_400
        post '/0.1/vrp/graph',
             { api_key: 'demo', vrp: {} }.to_json,
             'CONTENT_TYPE' => 'application/json'

        assert_equal 400, last_response.status
      end
    end
  end
end
