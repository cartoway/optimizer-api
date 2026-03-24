# frozen_string_literal: true

require './test/test_helper'

module VrpGraph
  class GraphBuilderTest < Minitest::Test
    def setup
      return if File.executable?(VrpGraph::DelaunayAdapter::BINARY_PATH)

      skip 'vrp_delaunay binary not built (rake ext:vrp_delaunay)'
    end

    def test_build_creates_graph_with_service_level_nodes
      vrp = TestHelper.create(TestHelper.load_vrp(self, fixture_file: 'instance_andalusia'))
      graph = GraphBuilder.new(vrp).build
      assert graph
      assert graph.is_a?(Models::Graph)
      assert graph.nodes.any?

      # Each node key should be a service_id and carry a point_id back-reference
      graph.nodes.each do |service_id, data|
        assert_kind_of String, service_id.to_s
        assert data[:point_id], "Node #{service_id} should have :point_id"
        assert data[:point], "Node #{service_id} should have :point"
        assert data[:point][:lat], "Node #{service_id} should have lat"
        assert data[:point][:lon], "Node #{service_id} should have lon"
      end

      # Edges should reference existing node keys (service_ids)
      graph.edges.each do |e|
        sid_a, sid_b = e[0], e[1]
        assert graph.nodes.key?(sid_a) || graph.nodes.key?(sid_a.to_s),
               "Edge references unknown service_id: #{sid_a}"
        assert graph.nodes.key?(sid_b) || graph.nodes.key?(sid_b.to_s),
               "Edge references unknown service_id: #{sid_b}"
      end
    end

    def test_graph_to_geojson
      vrp = TestHelper.create(TestHelper.load_vrp(self, fixture_file: 'instance_andalusia'))
      graph = GraphBuilder.new(vrp).build
      geojson = graph.to_geojson
      assert geojson
      assert_equal 'FeatureCollection', geojson['type']
      assert geojson['features'].is_a?(Array)

      point_features = geojson['features'].select{ |f| f['geometry']['type'] == 'Point' }
      assert point_features.any?
      point_features.each do |f|
        props = f['properties']
        assert props['service_id'], "GeoJSON Point feature should have service_id"
        assert props['point_id'], "GeoJSON Point feature should have point_id"
      end
    end

    def test_tours_connectivity_from_solution
      vrp = TestHelper.create(TestHelper.load_vrp(self, fixture_file: 'instance_andalusia'))
      graph = GraphBuilder.new(vrp).build
      solution = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:demo] } }, vrp, nil).first
      return skip 'No solution' unless solution&.routes&.any?

      conn = graph.tours_connectivity_from_solution(solution)
      assert conn.is_a?(Hash)
    end

    def test_neighbors_for_service_and_point
      vrp = TestHelper.create(TestHelper.load_vrp(self, fixture_file: 'instance_andalusia'))
      graph = GraphBuilder.new(vrp).build

      if graph.knn_neighbors.any?
        sid = graph.knn_neighbors.keys.first
        neighbors = graph.neighbors_for_service(sid)
        assert neighbors.is_a?(Array)

        pid = graph.nodes[sid][:point_id]
        point_neighbors = graph.neighbors_for_point(pid)
        assert point_neighbors.is_a?(Array)
      end
    end

    def test_intra_point_edges_between_colocated_services
      # Build a minimal VRP where 2 services share the same point
      problem = VRP.basic
      point_id = problem[:points].first[:id]
      problem[:services] = [
        { id: 'svc_a', activity: { point_id: point_id, duration: 10 }, skills: ['alpha'] },
        { id: 'svc_b', activity: { point_id: point_id, duration: 10 }, skills: ['alpha'] }
      ]
      problem[:vehicles] = [
        { id: 'v1', start_point_id: point_id, skills: [['alpha']],
          router_mode: 'car', speed_multiplier: 1.0 }
      ]

      vrp = TestHelper.create(problem)
      graph = GraphBuilder.new(vrp).build

      if graph
        assert graph.nodes.key?('svc_a'), 'Should have node for svc_a'
        assert graph.nodes.key?('svc_b'), 'Should have node for svc_b'

        assert_equal graph.nodes['svc_a'][:point_id], graph.nodes['svc_b'][:point_id],
                     'Co-located services should share the same point_id'

        intra_edge =
          graph.edges.any?{ |e|
            [e[0], e[1]].sort == ['svc_a', 'svc_b'].sort
          }
        assert intra_edge, 'Compatible co-located services should have an intra-point edge'
      end
    end

    def test_build_per_skill_returns_multi_graph
      vrp = TestHelper.create(TestHelper.load_vrp(self, fixture_file: 'instance_andalusia'))
      multi = GraphBuilder.new(vrp).build_per_skill
      assert multi, 'build_per_skill should return a non-nil object'
      assert_kind_of Models::MultiGraph, multi
      assert multi.graphs.is_a?(Hash)

      multi.graphs.each do |skill_key, graph|
        assert_kind_of Models::Graph, graph
        assert graph.nodes.any?, "Graph for skill '#{skill_key}' should have nodes"
      end

      assert multi.nodes.any?, 'Merged nodes should be non-empty'
      assert multi.edges.is_a?(Array)
    end

    def test_build_per_skill_separate_skill_groups
      problem = VRP.basic
      points = problem[:points]
      problem[:services] = [
        { id: 'sa', activity: { point_id: points[0][:id], duration: 10 }, skills: ['alpha'] },
        { id: 'sb', activity: { point_id: points[1][:id], duration: 10 }, skills: ['beta'] },
        { id: 'sc', activity: { point_id: points[0][:id], duration: 10 } },
        { id: 'sd', activity: { point_id: points[1][:id], duration: 10 }, skills: %w[alpha beta] }
      ]
      problem[:vehicles] = [
        { id: 'v1', start_point_id: points[0][:id], skills: [['alpha']],
          router_mode: 'car', speed_multiplier: 1.0 },
        { id: 'v2', start_point_id: points[0][:id], skills: [['beta']],
          router_mode: 'car', speed_multiplier: 1.0 },
        { id: 'v3', start_point_id: points[0][:id], skills: [%w[alpha beta]],
          router_mode: 'car', speed_multiplier: 1.0 }
      ]

      vrp = TestHelper.create(problem)
      multi = GraphBuilder.new(vrp).build_per_skill

      assert_kind_of Models::MultiGraph, multi

      # Graph keys = unique skill-set combinations
      assert multi.graphs.key?('alpha'), 'Should have graph for skill-set [alpha]'
      assert multi.graphs.key?('beta'), 'Should have graph for skill-set [beta]'
      assert multi.graphs.key?('alpha,beta'), 'Should have graph for skill-set [alpha,beta]'
      refute multi.graphs.key?(nil), 'No separate nil graph when skilled services exist'

      # Each service is in its own skill-set graph
      assert multi.graphs['alpha'].nodes.key?('sa'), 'sa should be in alpha graph'
      assert multi.graphs['beta'].nodes.key?('sb'), 'sb should be in beta graph'
      assert multi.graphs['alpha,beta'].nodes.key?('sd'), 'sd should be in alpha,beta graph'

      # No-skill service sc (bridge): present in ALL graphs
      assert multi.graphs['alpha'].nodes.key?('sc'), 'sc (no skills) should be in alpha graph'
      assert multi.graphs['beta'].nodes.key?('sc'), 'sc (no skills) should be in beta graph'
      assert multi.graphs['alpha,beta'].nodes.key?('sc'), 'sc (no skills) should be in alpha,beta graph'

      # Skill intersection: sd [alpha,beta] shares skills with both [alpha] and [beta]
      assert multi.graphs['alpha'].nodes.key?('sd'), 'sd [alpha,beta] should be in alpha graph (shares alpha)'
      assert multi.graphs['beta'].nodes.key?('sd'), 'sd [alpha,beta] should be in beta graph (shares beta)'

      # sa [alpha] shares alpha with [alpha,beta] graph
      assert multi.graphs['alpha,beta'].nodes.key?('sa'), 'sa [alpha] should be in alpha,beta graph (shares alpha)'
      # sb [beta] shares beta with [alpha,beta] graph
      assert multi.graphs['alpha,beta'].nodes.key?('sb'), 'sb [beta] should be in alpha,beta graph (shares beta)'

      # sa [alpha] does NOT share any skill with [beta] graph
      refute multi.graphs['beta'].nodes.key?('sa'), 'sa [alpha] should not be in beta graph (no common skill)'
      # sb [beta] does NOT share any skill with [alpha] graph
      refute multi.graphs['alpha'].nodes.key?('sb'), 'sb [beta] should not be in alpha graph (no common skill)'
    end

    def test_build_per_skill_no_skills_single_graph
      problem = VRP.basic
      problem[:services].each { |s| s.delete(:skills) }
      problem[:vehicles].each { |v| v.delete(:skills) }

      vrp = TestHelper.create(problem)
      multi = GraphBuilder.new(vrp).build_per_skill

      assert_kind_of Models::MultiGraph, multi
      assert_equal 1, multi.graphs.size, 'Should have a single graph when no skills exist'
      assert multi.graphs.key?(nil), 'Single graph should be keyed by nil'
    end
  end
end
