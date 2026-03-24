# frozen_string_literal: true

require './test/test_helper'

module VrpGraph
  class DelaunayAdapterTest < Minitest::Test
    def setup
      return if File.executable?(VrpGraph::DelaunayAdapter::BINARY_PATH)

      skip 'vrp_delaunay binary not built (rake ext:vrp_delaunay)'
    end

    def test_compute_edges_returns_empty_for_insufficient_points
      assert_empty DelaunayAdapter.compute_edges([])
      assert_empty DelaunayAdapter.compute_edges([[1.0, 2.0]])
    end

    def test_compute_edges_two_points
      points = [[0.0, 0.0], [1.0, 1.0]]
      edges = DelaunayAdapter.compute_edges(points)
      assert_equal [[0, 1]], edges
    end

    def test_compute_edges_three_points_triangle
      points = [[0.0, 0.0], [1.0, 0.0], [0.5, 1.0]]
      edges = DelaunayAdapter.compute_edges(points)
      assert_equal 3, edges.size
      assert_includes edges, [0, 1]
      assert_includes edges, [1, 2]
      assert_includes edges, [0, 2]
    end

    def test_compute_edges_four_points
      points = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]
      edges = DelaunayAdapter.compute_edges(points)
      assert edges.size >= 3
      edges.each do |a, b|
        assert a < b, "Edges should be ordered (i < j): #{[a, b]}"
        assert a < points.size && b < points.size
      end
    end
  end
end
