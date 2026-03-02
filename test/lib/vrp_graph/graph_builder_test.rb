# frozen_string_literal: true

require './test/test_helper'

module VrpGraph
  class GraphBuilderTest < Minitest::Test
    def setup
      skip 'vrp_delaunay binary not built (rake ext:vrp_delaunay)' unless File.executable?(VrpGraph::DelaunayAdapter::BINARY_PATH)
    end

    def test_build_creates_graph_from_vrp
      vrp = TestHelper.create(TestHelper.load_vrp(self, fixture_file: 'instance_andalusia'))
      graph = GraphBuilder.new(vrp).build
      assert graph
      assert graph.is_a?(Models::Graph)
      assert graph.nodes.any?
      assert graph.edges.any? || graph.nodes.size < 2
    end

    def test_graph_to_geojson
      vrp = TestHelper.create(TestHelper.load_vrp(self, fixture_file: 'instance_andalusia'))
      graph = GraphBuilder.new(vrp).build
      geojson = graph.to_geojson
      assert geojson
      assert geojson['type'] == 'FeatureCollection'
      assert geojson['features'].is_a?(Array)
    end

    def test_tours_connectivity_from_solution
      vrp = TestHelper.create(TestHelper.load_vrp(self, fixture_file: 'instance_andalusia'))
      graph = GraphBuilder.new(vrp).build
      solution = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:demo] } }, vrp, nil).first
      return skip 'No solution' unless solution&.routes&.any?

      conn = graph.tours_connectivity_from_solution(solution)
      assert conn.is_a?(Hash)
    end
  end
end
