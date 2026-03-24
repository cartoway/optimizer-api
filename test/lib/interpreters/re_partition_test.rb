require './test/test_helper'
require './lib/interpreters/re_partition'

class RePartitionTest < IsolatedTest
  # Happy path: Solution#vrp_routes rows survive Models.delete_all + Vrp.reload.
  def test_vrp_routes_rebuild_after_delete_all
    vrp = TestHelper.create(VRP.basic)
    vehicle = vrp.vehicles.first
    service = vrp.services.first
    stop = Models::Solution::Stop.new(service)
    solution_route = Models::Solution::Route.new(vehicle: vehicle, stops: [stop])
    solution = Models::Solution.new(routes: [solution_route])

    built =
      solution.routes.filter_map{ |route|
        missions = route.missions_for_initial_routes
        next if missions.empty?

        Models::Route.create(vehicle: route.vehicle, missions: missions)
      }
    refute_empty built

    rows = solution.vrp_routes
    assert_equal built.size, rows.size

    vrp_hash = vrp.as_json
    Models.delete_all
    vrp2 = Models::Vrp.create(vrp_hash, check: false)

    rebuilt = vrp2.routes_from_initial_specs(rows)
    assert_equal built.map(&:mission_ids), rebuilt.map(&:mission_ids)
    assert_equal built.map(&:vehicle_id), rebuilt.map(&:vehicle_id)
  end

  def test_validate_repartition_raises_on_duplicate_service_assignment
    vrp = TestHelper.create(VRP.basic)
    vehicle = vrp.vehicles.first
    s1 = vrp.services.first
    r =
      Models::Solution::Route.new(
        vehicle: vehicle,
        stops: [Models::Solution::Stop.new(s1), Models::Solution::Stop.new(s1)]
      )
    sol = Models::Solution.new(routes: [r], unassigned_stops: [])
    err =
      assert_raises(Interpreters::RePartition::DuplicateAssignmentError) do
        Interpreters::RePartition.send(:validate_repartition_solution_no_duplicates!, sol, vrp, 'test')
      end
    assert_match(/service/, err.message)
  end

  def test_validate_repartition_raises_on_two_mission_routes_same_vehicle
    vrp = TestHelper.create(VRP.basic)
    vehicle = vrp.vehicles.first
    s1, s2 = vrp.services.first(2)
    r1 = Models::Solution::Route.new(vehicle: vehicle, stops: [Models::Solution::Stop.new(s1)])
    r2 = Models::Solution::Route.new(vehicle: vehicle, stops: [Models::Solution::Stop.new(s2)])
    sol = Models::Solution.new(routes: [r1, r2], unassigned_stops: [])
    err =
      assert_raises(Interpreters::RePartition::DuplicateAssignmentError) do
        Interpreters::RePartition.send(:validate_repartition_solution_no_duplicates!, sol, vrp, 'test')
      end
    assert_match(/2 routes/, err.message)
  end

  def test_damped_neighbor_weight
    rp = Interpreters::RePartition
    assert_equal 0.0, rp.send(:damped_neighbor_weight, 0)
    assert_equal 0.0, rp.send(:damped_neighbor_weight, -3)
    p = Interpreters::RePartition::NEIGHBOR_WEIGHT_POWER
    assert_in_delta 9.0**p, rp.send(:damped_neighbor_weight, 9), 1e-9
  end

  def test_weighted_random_pick_deterministic_with_same_rng
    rp = Interpreters::RePartition
    cands = [%w[low 1.0], %w[high 4.0]]
    rng = Random.new(123_456)
    a = rp.send(:weighted_random_pick, cands, rng: rng)
    b = rp.send(:weighted_random_pick, cands, rng: Random.new(123_456))
    assert_equal a, b
  end

  def test_batch_covers_unassigned_service_skills_and_days
    problem =
      VRP.basic.merge(
        vehicles: [
          {
            id: 'v_skill_a_mon',
            matrix_id: 'matrix_0',
            start_point_id: 'point_0',
            skills: [['skill_a']],
            timewindow: { day_index: 1, start: 0, end: 86_400 },
          },
          {
            id: 'v_skill_b_tue',
            matrix_id: 'matrix_0',
            start_point_id: 'point_0',
            skills: [['skill_b']],
            timewindow: { day_index: 2, start: 0, end: 86_400 },
          },
        ],
        services:
          VRP.basic[:services] + [
            {
              id: 's_extra_a',
              skills: [:skill_a],
              activity: {
                point_id: 'point_1',
                timewindows: [{ day_index: 1, start: 0, end: 500 }],
              },
            },
            {
              id: 's_extra_b',
              skills: [:skill_b],
              activity: {
                point_id: 'point_2',
                timewindows: [{ day_index: 2, start: 0, end: 500 }],
              },
            },
            {
              id: 's_skill_a_wrong_day',
              skills: [:skill_a],
              activity: {
                point_id: 'point_3',
                timewindows: [{ day_index: 3, start: 0, end: 500 }],
              },
            },
          ]
      )

    vrp = TestHelper.create(problem)
    s_a = vrp.services.find{ |s| s.id == 's_extra_a' }
    s_b = vrp.services.find{ |s| s.id == 's_extra_b' }
    s_wrong = vrp.services.find{ |s| s.id == 's_skill_a_wrong_day' }
    vehicles_by_batch = { 0 => ['v_skill_a_mon'], 1 => ['v_skill_b_tue'] }

    assert Interpreters::RePartition.send(:batch_covers_unassigned_service?, vrp, vehicles_by_batch, 0, s_a)
    refute Interpreters::RePartition.send(:batch_covers_unassigned_service?, vrp, vehicles_by_batch, 1, s_a)
    refute Interpreters::RePartition.send(:batch_covers_unassigned_service?, vrp, vehicles_by_batch, 0, s_b)
    assert Interpreters::RePartition.send(:batch_covers_unassigned_service?, vrp, vehicles_by_batch, 1, s_b)
    refute Interpreters::RePartition.send(:batch_covers_unassigned_service?, vrp, vehicles_by_batch, 0, s_wrong)
    refute Interpreters::RePartition.send(:batch_covers_unassigned_service?, vrp, vehicles_by_batch, 1, s_wrong)
  end

  def test_vrp_routes_for_vehicles_filters_by_fleet
    vrp = TestHelper.create(VRP.basic)
    vehicle = vrp.vehicles.first
    service = vrp.services.first
    stop = Models::Solution::Stop.new(service)
    solution_route = Models::Solution::Route.new(vehicle: vehicle, stops: [stop])
    solution = Models::Solution.new(routes: [solution_route])

    rows = solution.vrp_routes
    refute_empty rows

    assert_empty Models::Solution.vrp_routes_for_vehicles(rows, [])
    assert_equal rows,
                 Models::Solution.vrp_routes_for_vehicles(rows, [vehicle.id])
  end

  def test_repartition_disabled_for_small_vrp
    vrp = TestHelper.create(VRP.basic)

    vrp.configuration.resolution.dicho_algorithm_vehicle_limit = 10
    vrp.configuration.resolution.dicho_algorithm_service_limit = 100

    service_vrp = Models::ResolutionContext.new(service: :ortools, vrp: vrp)

    result = Interpreters::RePartition.repartition(service_vrp)

    assert_nil result
  end

  def test_repartition_integration_with_define_process
    problem = VRP.lat_lon_two_vehicles
    problem[:configuration] ||= {}
    problem[:configuration][:resolution] ||= {}
    problem[:configuration][:resolution][:duration] ||= 100
    problem[:configuration][:resolution][:dicho_algorithm_vehicle_limit] = 1
    problem[:configuration][:resolution][:dicho_algorithm_service_limit] = 5
    problem[:configuration][:restitution] ||= { intermediate_solutions: false }

    vrp = TestHelper.create(problem)
    service_vrp = Models::ResolutionContext.new(service: :ortools, vrp: vrp)

    inner_graph = Models::Graph.new(
      nodes: {}, edges: [], incompatibilities: [], knn_neighbors: {}, metadata: {}
    )
    fake_graph = Models::MultiGraph.new(graphs: { nil => inner_graph })

    Interpreters::RePartition.stub(:build_graph, fake_graph) do
      solutions =
        Core::Strategies::Orchestration.define_main_process(
          [service_vrp],
          nil
        ) { |_wrapper, _avancement, _total, _message, _cost, _time, _solution| }

      solution = solutions.first

      assert_kind_of Models::Solution, solution
      refute_nil solution.routes
    end
  end
end
