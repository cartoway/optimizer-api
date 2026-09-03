require './test/test_helper'

class Wrappers::PyVRPTest < Minitest::Test
  def setup
    @pyvrp = OptimizerWrapper.config[:services][:pyvrp]
    @minimal_problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 1],
          [1, 0]
        ],
        distance: [
          [0, 1],
          [1, 0]
        ]
      }],
      points: [{
        id: 'point_0',
        matrix_index: 0
      }, {
        id: 'point_1',
        matrix_index: 1
      }],
      vehicles: [{
        id: 'vehicle_0',
        start_point_id: 'point_0',
        matrix_id: 'matrix_0'
      }],
      services: [{
        id: 'service_0',
        activity: {
          point_id: 'point_0'
        }
      }, {
        id: 'service_1',
        activity: {
          point_id: 'point_1'
        }
      }],
      configuration: {
        resolution: {
          duration: 1000
        }
      }
    }
    @problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 655, 1948, 5231, 2971],
          [603, 0, 1692, 4977, 2715],
          [1861, 1636, 0, 6143, 1532],
          [5184, 4951, 6221, 0, 7244],
          [2982, 2758, 1652, 7264, 0],
        ], distance: [
          [0, 655, 1948, 5231, 2971],
          [603, 0, 1692, 4977, 2715],
          [1861, 1636, 0, 6143, 1532],
          [5184, 4951, 6221, 0, 7244],
          [2982, 2758, 1652, 7264, 0],
        ]
      }],
      points: [{
        id: 'point_0',
        matrix_index: 0
      }, {
        id: 'point_1',
        matrix_index: 1
      }, {
        id: 'point_2',
        matrix_index: 2
      }, {
        id: 'point_3',
        matrix_index: 3
      }, {
        id: 'point_4',
        matrix_index: 4
      }],
      vehicles: [{
        id: 'vehicle_0',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        matrix_id: 'matrix_0'
      }],
      services: [{
        id: 'service_1',
        activity: {
          point_id: 'point_1'
        }
      }, {
        id: 'service_2',
        activity: {
          point_id: 'point_2'
        }
      }, {
        id: 'service_3',
        activity: {
          point_id: 'point_3'
        }
      }, {
        id: 'service_4',
        activity: {
          point_id: 'point_4'
        }
      }],
    }
  end

  def test_minimal_problem
    vrp = TestHelper.create(@minimal_problem)

    solution = @pyvrp.solve(vrp)

    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @minimal_problem[:services].size + 1, solution.routes.first.stops.size
  end

  def test_loop_problem
    vrp = TestHelper.create(@problem)
    solution = @pyvrp.solve(vrp)
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @problem[:services].size + 2, solution.routes.first.stops.size
    assert_equal @problem[:services].collect{ |s| s[:id] }.sort!, solution.routes.first.stops[1..-2].map(&:id).sort!
  end

  def test_no_end_problem
    @problem[:vehicles][0].delete(:end_point_id)
    vrp = TestHelper.create(@problem)
    solution = @pyvrp.solve(vrp)
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @problem[:services].size + 1, solution.routes.first.stops.size
    assert_equal @problem[:services].collect{ |s| s[:id] }.sort!, solution.routes.first.stops[1..].map(&:id).sort!
  end

  def test_start_different_end_problem
    @problem[:vehicles][0][:end_point_id] = 'point_4'
    vrp = TestHelper.create(@problem)
    solution = @pyvrp.solve(vrp)
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @problem[:services].size + 2, solution.routes.first.stops.size
    assert_equal @problem[:services].collect{ |s| s[:id] }.sort!, solution.routes.first.stops[1..-2].map(&:id).sort!
  end

  def test_vehicle_time_window
    @minimal_problem[:vehicles][0][:timewindow] = {
      start: 1,
      end: 10
    }
    vrp = TestHelper.create(@minimal_problem)
    solution = @pyvrp.solve(vrp)
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @minimal_problem[:services].size + 1, solution.routes.first.stops.size
  end

  # API sends shift_preference as a string; build_depots must match :force_start
  # so depots are not dropped from the PyVRP JSON.
  def test_shift_preference_force_start_string_builds_depots
    vehicle = @minimal_problem[:vehicles][0].dup
    vehicle[:shift_preference] = 'force_start'
    vehicle[:timewindow] = { start: 5, end: 100 }
    vehicle[:end_point_id] = 'point_0'
    problem = @minimal_problem.merge(vehicles: [vehicle])
    vrp = TestHelper.create(problem)
    payload = Wrappers::PyVRP.new.send(:pyvrp_problem, vrp)
    refute_empty payload[:depots]
    refute(payload[:depots].any?(&:nil?), 'PyVRP JSON depots must not contain nil slots (index collision)')
    assert(payload[:depots].any?{ |d| d[:name].to_s.include?('force_start') })

    solution = @pyvrp.solve(vrp)
    assert solution
  end

  # Distinct start/end with force_start used to allocate duplicate depot indices (standard hash used local size).
  def test_shift_preference_force_start_distinct_end_point_no_nil_depots
    vehicle = @minimal_problem[:vehicles][0].dup
    vehicle[:shift_preference] = 'force_start'
    vehicle[:timewindow] = { start: 5, end: 100 }
    vehicle[:end_point_id] = 'point_1'
    problem = @minimal_problem.merge(vehicles: [vehicle])
    vrp = TestHelper.create(problem)
    payload = Wrappers::PyVRP.new.send(:pyvrp_problem, vrp)
    refute(payload[:depots].any?(&:nil?), 'expected distinct global indices for start vs end depot rows')
    assert_equal 2, payload[:depots].size

    solution = @pyvrp.solve(vrp)
    assert solution
  end

  def test_pyvrp_with_self_selection
    vrp = VRP.basic
    vrp[:configuration][:preprocessing][:first_solution_strategy] = ['self_selection']

    pyvrp_counter = 0
    OptimizerWrapper.config[:services][:pyvrp].stub(
      :solve,
      lambda { |vrp_in, _job, _thread_prod|
        pyvrp_counter += 1
        # Return empty result to make sure the code continues regularly
        Models::Solution.new(
          solvers: [:pyvrp],
          unassigned_stops: vrp_in.services.map{ |service| Models::Solution::Stop.new(service) }
        )
      }
    ) do
      OptimizerWrapper.wrapper_vrp('pyvrp', { services: { vrp: [:pyvrp] }}, TestHelper.create(vrp), nil)
    end
    assert_equal 1, pyvrp_counter
  end

  def test_ensure_total_time_and_travel_info_with_pyvrp
    vrp = VRP.basic
    vrp[:matrices].first[:distance] = vrp[:matrices].first[:time]
    solutions = OptimizerWrapper.wrapper_vrp('pyvrp', { services: { vrp: [:pyvrp] }}, TestHelper.create(vrp), nil)
    assert solutions[0].routes.all?{ |route|
             route.stops.empty? || route.info.total_time
           }, 'At least one route total_time was not provided'
    assert solutions[0].routes.all?{ |route|
             route.stops.empty? || route.info.total_travel_time
           }, 'At least one route total_travel_time was not provided'
    assert solutions[0].routes.all?{ |route|
             route.stops.empty? || route.info.total_distance
           }, 'At least one route total_travel_distance was not provided'
  end

  def test_solver_schedule_is_preserved
    problem = @minimal_problem.dup
    problem[:vehicles][0][:end_point_id] = 'point_0'
    problem[:services].each{ |service| service[:activity][:duration] = 10 }
    @pyvrp.stub(
      :run_pyvrp, lambda{ |_payload, _timeout|
        map = @pyvrp.instance_variable_get(:@service_index_map)
        indices = map.each_with_index.filter_map{ |service, idx| idx if service }
        start_depot = @pyvrp.instance_variable_get(:@vehicle_start_point_index_hash)['vehicle_0']
        {
          runtime: 0.01,
          iterations: 1,
          cost: 100,
          feasible: true,
          complete: true,
          routes: [{
            vehicle_type: 0,
            activities: [
              { type: 'client', idx: indices[0], start_time: 200, end_time: 210, wait_duration: 40 },
              { type: 'client', idx: indices[1], start_time: 250, end_time: 260, wait_duration: 0 }
            ],
            start_depot: start_depot,
            end_depot: start_depot,
            start_time: 100,
            end_time: 300,
            start_schedule: { start_time: 100, end_time: 100, wait_duration: 0 },
            end_schedule: { start_time: 300, end_time: 300, wait_duration: 0 }
          }]
        }
      }
    ) do
      solution = @pyvrp.solve(TestHelper.create(problem), 'test')
      route = solution.routes.first
      assert_equal 100, route.stops.first.info.begin_time
      assert_equal 200, route.stops[1].info.begin_time
      assert_equal 40, route.stops[1].info.waiting_time
      assert_equal 210, route.stops[1].info.end_time
      assert_equal 250, route.stops[2].info.begin_time
      assert_equal 300, route.stops.last.info.begin_time
      assert_equal 100, route.info.start_time
      assert_equal 300, route.info.end_time
    end
  end

  def test_solver_schedule_falls_back_to_route_times_for_depots
    problem = @minimal_problem.dup
    problem[:vehicles][0][:end_point_id] = 'point_0'
    problem[:services].each{ |service| service[:activity][:duration] = 10 }
    @pyvrp.stub(
      :run_pyvrp, lambda{ |_payload, _timeout|
        map = @pyvrp.instance_variable_get(:@service_index_map)
        indices = map.each_with_index.filter_map{ |service, idx| idx if service }
        start_depot = @pyvrp.instance_variable_get(:@vehicle_start_point_index_hash)['vehicle_0']
        {
          runtime: 0.01,
          iterations: 1,
          cost: 100,
          feasible: true,
          complete: true,
          routes: [{
            vehicle_type: 0,
            activities: [
              { type: 'client', idx: indices[0], start_time: 200, end_time: 210, wait_duration: 0 },
              { type: 'client', idx: indices[1], start_time: 250, end_time: 260, wait_duration: 0 }
            ],
            start_depot: start_depot,
            end_depot: start_depot,
            start_time: 100,
            end_time: 300
          }]
        }
      }
    ) do
      solution = @pyvrp.solve(TestHelper.create(problem), 'test')
      route = solution.routes.first
      assert_equal 100, route.stops.first.info.begin_time
      assert_equal 300, route.stops.last.info.begin_time
      assert_equal 300, route.stops.last.info.end_time
    end
  end

  def test_solver_schedule_respects_timewindows
    problem = @minimal_problem.dup
    problem[:vehicles][0][:end_point_id] = 'point_0'
    problem[:vehicles][0][:timewindow] = { start: 50, end: 500 }
    problem[:services].each{ |service|
      service[:activity][:duration] = 10
      service[:activity][:timewindows] = [{ start: 100, end: 400 }]
    }
    solution = @pyvrp.solve(TestHelper.create(problem), 'test')
    route = solution.routes.find{ |r| r.stops.any?(&:service_id) }
    assert route, 'Expected an assigned route'
    assert_operator route.stops.first.info.begin_time, :>=, 50
    refute_equal 0, route.stops.first.info.begin_time
    route.stops.select(&:service_id).each{ |stop|
      assert_operator stop.info.begin_time, :>=, 100
      assert_operator stop.info.begin_time, :<=, 400
    }
    assert_operator route.stops.last.info.begin_time, :<=, 500
  end

  def test_correct_route_collection
    problem = VRP.lat_lon_two_vehicles
    problem[:services].each{ |service|
      service[:skills] = ['s1']
    }
    problem[:vehicles].last[:skills] = [['s1']]

    solutions = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:pyvrp] }}, TestHelper.create(problem), nil)
    assert_equal 2, solutions[0].routes.size

    skilled_route = solutions[0].routes.find{ |route| route.vehicle.id == problem[:vehicles].last[:id] }
    assert_equal problem[:services].size, skilled_route.stops.count(&:service_id)
  end

  def test_quantity_precision
    problem = VRP.basic
    problem[:services].each{ |service|
      service[:quantities] = [{ unit_id: 'kg', value: 1.001 }]
    }
    problem[:vehicles].each{ |vehicle|
      vehicle[:capacities] = [{ unit_id: 'kg', limit: 3 }]
    }

    solutions = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:pyvrp] }}, TestHelper.create(problem), nil)
    assert_equal 1, solutions[0].unassigned_stops.size, 'The solution is expected to contain 1 unassigned'

    assert_operator solutions[0].routes.first.stops.count(&:service_id), :<=, 2,
                    'The vehicle cannot load more than 2 services and 3 kg'
    solutions[0].routes.first.stops.each{ |activity|
      next unless activity.service_id

      assert_equal 1.001, activity.loads.first.quantity.value
    }
  end

  def test_quantity_precision_with_pickup
    problem = VRP.basic
    problem[:services].each{ |service|
      service[:quantities] = [{ unit_id: 'kg', pickup: 1.001 }]
    }
    problem[:vehicles].each{ |vehicle|
      vehicle[:capacities] = [{ unit_id: 'kg', limit: 3 }]
    }

    solutions = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:pyvrp] }}, TestHelper.create(problem), nil)
    assert_equal 1, solutions[0].unassigned_stops.size, 'The result is expected to contain 1 unassigned'

    assert_operator solutions[0].routes.first.stops.count(&:service_id), :<=, 2,
                    'The vehicle cannot load more than 2 services and 3 kg'
    solutions[0].routes.first.stops.each{ |activity|
      next unless activity.service_id

      assert_equal 1.001, activity.loads.first.quantity.pickup
    }
  end

  def test_quantity_precision_with_delivery
    problem = VRP.basic
    problem[:services].each{ |service|
      service[:quantities] = [{ unit_id: 'kg', delivery: 1.001 }]
    }
    problem[:vehicles].each{ |vehicle|
      vehicle[:capacities] = [{ unit_id: 'kg', limit: 3 }]
    }

    solutions = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:pyvrp] }}, TestHelper.create(problem), nil)
    assert_equal 1, solutions[0].unassigned_stops.size, 'The result is expected to contain 1 unassigned'

    assert_operator solutions[0].routes.first.stops.count(&:service_id), :<=, 2,
                    'The vehicle cannot load more than 2 services and 3 kg'
    solutions[0].routes.first.stops.each{ |activity|
      next unless activity.service_id

      assert_equal 1.001, activity.loads.first.quantity.delivery
    }
  end

  def test_negative_quantities_should_not_raise
    problem = VRP.basic
    problem[:units] << { id: 'l' }
    problem[:services].each{ |service|
      service[:quantities] = [{ unit_id: 'kg', value: 1 }, { unit_id: 'l', value: -1}]
    }
    problem[:vehicles].each{ |vehicle|
      vehicle[:capacities] = [{ unit_id: 'kg', limit: 3 }, { unit_id: 'l', limit: 2}]
    }
    OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:pyvrp] }}, TestHelper.create(problem), nil)
  end

  def test_clients_pickup_delivery_aligned_with_vehicle_capacity
    problem = VRP.basic
    problem[:units] << { id: 'l' }
    problem[:services].each{ |service|
      service[:quantities] = [
        { unit_id: 'kg', delivery: 1 },
        { unit_id: 'l', pickup: 2 }
      ]
    }
    problem[:vehicles].each{ |vehicle|
      vehicle[:capacities] = [{ unit_id: 'kg', limit: 3 }, { unit_id: 'l', limit: 0 }]
    }

    pyvrp = Wrappers::PyVRP.new
    pyvrp.stub(
      :run_pyvrp, lambda{ |pyvrp_vrp, _timeout|
        capacity_size = pyvrp_vrp[:vehicle_types].first[:capacity].size
        pyvrp_vrp[:clients].each{ |client|
          assert_equal capacity_size, client[:delivery].size
          assert_equal capacity_size, client[:pickup].size
        }
        nil
      }
    ) do
      @pyvrp.solve(TestHelper.create(problem))
    end
  end

  def test_partially_nil_capacities
    problem = VRP.basic
    problem[:services].each{ |service|
      service[:quantities] = [{ unit_id: 'kg', value: 1 }]
    }
    problem[:vehicles] << problem[:vehicles].first.dup
    problem[:vehicles].first[:capacities] = [{ unit_id: 'kg', limit: 2 }]
    problem[:vehicles].last[:id] = 'vehicle_1'

    empty_result = { feasible: true, complete: true, routes: [], runtime: 0, cost: 0 }
    @pyvrp.stub(
      :run_pyvrp, lambda{ |payload, _timeout|
        limited = payload[:vehicle_types].find{ |vehicle| vehicle[:name] == 'vehicle_0' }
        unbounded = payload[:vehicle_types].find{ |vehicle| vehicle[:name] == 'vehicle_1' }
        assert_equal 2 * Wrappers::PyVRP::CUSTOM_QUANTITY_BIGNUM, limited[:capacity].first
        demand = payload[:clients].sum{ |client| client[:pickup].first }
        assert_equal demand, unbounded[:capacity].first
        empty_result
      }
    ) do
      @pyvrp.solve(TestHelper.create(problem))
    end
  end

  def test_unbounded_timewindows_use_horizon_not_max_int64
    problem = @minimal_problem.dup
    empty_result = { feasible: true, complete: true, routes: [], runtime: 0, cost: 0 }
    @pyvrp.stub(
      :run_pyvrp, lambda{ |payload, _timeout|
        payload[:clients].each{ |client|
          refute_equal Wrappers::PyVRP::MAX_INT64, client[:tw_late]
          assert_operator client[:tw_late], :>, 0
        }
        payload[:vehicle_types].each{ |vehicle|
          refute_equal Wrappers::PyVRP::MAX_INT64, vehicle[:tw_late]
          refute_equal Wrappers::PyVRP::MAX_INT64, vehicle[:shift_duration]
          refute_equal Wrappers::PyVRP::MAX_INT64, vehicle[:max_distance]
        }
        payload[:depots].each{ |depot|
          refute_equal Wrappers::PyVRP::MAX_INT64, depot[:tw_late]
        }
        empty_result
      }
    ) do
      @pyvrp.solve(TestHelper.create(problem))
    end
  end

  def test_time_horizon_follows_latest_timewindow_not_matrix_times_n
    problem = @minimal_problem.dup
    problem[:vehicles][0][:timewindow] = { start: 10_000, end: 20_000 }
    empty_result = { feasible: true, complete: true, routes: [], runtime: 0, cost: 0 }
    @pyvrp.stub(
      :run_pyvrp, lambda{ |payload, _timeout|
        payload[:clients].each{ |client|
          assert_equal 20_000, client[:tw_late]
        }
        vehicle = payload[:vehicle_types].first
        assert_equal 20_000, vehicle[:tw_late]
        assert_equal 20_000, vehicle[:shift_duration]
        empty_result
      }
    ) do
      @pyvrp.solve(TestHelper.create(problem))
    end
  end

  def test_universal_skills_are_not_load_dimensions
    problem = @minimal_problem.dup
    problem[:vehicles] = [
      {
        id: 'vehicle_0',
        start_point_id: 'point_0',
        matrix_id: 'matrix_0',
        skills: [['common', 'sector_a']]
      },
      {
        id: 'vehicle_1',
        start_point_id: 'point_0',
        matrix_id: 'matrix_0',
        skills: [['common', 'sector_b']]
      }
    ]
    problem[:services][0][:skills] = ['common', 'sector_a']
    problem[:services][1][:skills] = ['common', 'sector_b']
    empty_result = { feasible: true, complete: true, routes: [], runtime: 0, cost: 0 }
    demand = Wrappers::PyVRP::CUSTOM_QUANTITY_BIGNUM.round
    capacity = problem[:services].size * demand
    @pyvrp.stub(
      :run_pyvrp, lambda{ |payload, _timeout|
        # Two discriminating skills, no unit quantities, no universal 'common' dim.
        payload[:vehicle_types].each{ |vehicle|
          assert_equal 2, vehicle[:capacity].size
        }
        payload[:clients].each{ |client|
          assert_equal 2, client[:pickup].size
          assert_equal demand, client[:pickup].sum
        }
        assert_equal [capacity, 0], payload[:vehicle_types][0][:capacity]
        assert_equal [0, capacity], payload[:vehicle_types][1][:capacity]
        empty_result
      }
    ) do
      @pyvrp.solve(TestHelper.create(problem))
    end
  end

  def test_shift_duration_is_vehicle_duration_not_timewindow_width
    problem = @minimal_problem.dup
    problem[:vehicles][0][:timewindow] = { start: 10_000, end: 20_000 }
    empty_result = { feasible: true, complete: true, routes: [], runtime: 0, cost: 0 }
    @pyvrp.stub(
      :run_pyvrp, lambda{ |payload, _timeout|
        vehicle = payload[:vehicle_types].first
        refute_equal 10_000, vehicle[:shift_duration]
        assert_operator vehicle[:shift_duration], :>, 10_000
        refute_equal Wrappers::PyVRP::MAX_INT64, vehicle[:shift_duration]
        empty_result
      }
    ) do
      @pyvrp.solve(TestHelper.create(problem))
    end

    problem[:vehicles][0][:duration] = 4_000
    @pyvrp.stub(
      :run_pyvrp, lambda{ |payload, _timeout|
        assert_equal 4_000, payload[:vehicle_types].first[:shift_duration]
        empty_result
      }
    ) do
      @pyvrp.solve(TestHelper.create(problem))
    end
  end

  def test_multi_timewindow_group_is_required
    problem = @minimal_problem.dup
    problem[:services].first[:priority] = 0
    problem[:services].first[:activity][:timewindows] = [
      { start: 0, end: 10 },
      { start: 20, end: 30 }
    ]
    empty_result = { feasible: true, complete: true, routes: [], runtime: 0, cost: 0 }
    @pyvrp.stub(
      :run_pyvrp, lambda{ |payload, _timeout|
        grouped = payload[:clients].reject{ |client| client[:group].nil? }
        assert_equal 2, grouped.size
        grouped.each{ |client|
          refute client[:required]
          assert_equal 0, client[:prize]
        }
        assert_equal 1, payload[:groups].size
        assert payload[:groups].first[:required]
        assert_equal [0, 1], payload[:groups].first[:clients]
        empty_result
      }
    ) do
      @pyvrp.solve(TestHelper.create(problem))
    end
  end

  def test_multi_timewindow_clients_share_locations_and_point_sized_matrices
    problem = @minimal_problem.dup
    problem[:services].first[:activity][:timewindows] = [
      { start: 0, end: 10 },
      { start: 20, end: 30 }
    ]
    vrp = TestHelper.create(problem)
    payload = Wrappers::PyVRP.new.send(:pyvrp_problem, vrp)

    assert_equal 2, payload[:locations].size
    assert_equal payload[:locations].size, payload[:duration_matrices].first.size
    assert_equal payload[:locations].size, payload[:distance_matrices].first.size
    assert_equal 3, payload[:clients].size
    assert_equal payload[:locations].size, payload[:clients].map{ |client| client[:location] }.uniq.size
    payload[:clients].first(2).each{ |client|
      assert_equal payload[:clients].first[:location], client[:location]
    }
    refute payload[:clients].first.key?(:x)
    refute payload[:depots].first.key?(:x)
    payload[:locations].each{ |location|
      refute location.key?(:x)
      refute location.key?(:y)
    }
  end

  def test_seed_splits_route_when_capacity_exceeded
    problem = VRP.lat_lon_capacitated
    problem[:reload_depots] = [{
      id: 'reload_1',
      point_id: 'point_0'
    }]
    problem[:vehicles].first[:reload_depot_ids] = ['reload_1']
    problem[:vehicles].first[:maximum_reloads] = 4

    vrp = TestHelper.create(problem)
    vehicle = vrp.vehicles.first
    stops = vrp.services.map{ |service| Models::Solution::Stop.new(service) }
    solution = Models::Solution.new(
      routes: [Models::Solution::Route.new(vehicle: vehicle, stops: stops)],
      unassigned_stops: []
    )

    Wrappers::PyVRP.seed_vrp_routes_from_solution(vrp, solution)
    missions = vrp.routes.first.missions
    assert missions.any?{ |mission| mission.is_a?(Models::ReloadDepot) },
           'Capacity overflow should insert reload depots in the seed'
    assert_equal vrp.services.size, (missions.count { |mission| mission.is_a?(Models::Service) })
    assert_operator (missions.count { |mission| mission.is_a?(Models::ReloadDepot) }), :>=, 2
  end

  def test_multiple_matrices
    problem = VRP.lat_lon_two_vehicles
    problem[:matrices] << problem[:matrices].first.dup
    problem[:matrices].last[:id] = 'matrix_1'
    problem[:matrices].last[:time] = problem[:matrices].first[:time]

    vrp = TestHelper.create(problem)
    assert @pyvrp.solve(vrp, 'test')
  end

  def test_vehicle_heterogeneous_costs
    problem = VRP.lat_lon_two_vehicles
    problem[:vehicles].first[:cost_fixed] = 100
    problem[:vehicles].first[:cost_time_multiplier] = 1
    problem[:vehicles].first[:cost_distance_multiplier] = 1
    problem[:vehicles].last[:cost_fixed] = 200
    problem[:vehicles].last[:cost_time_multiplier] = 2
    problem[:vehicles].last[:cost_distance_multiplier] = 2
    vrp = TestHelper.create(problem)
    assert @pyvrp.solve(vrp, 'test')
  end

  def test_vehicle_max_distance
    problem = VRP.basic_max_distance
    problem[:vehicles].first[:distance] = 0
    vrp = TestHelper.create(problem)
    solution = @pyvrp.solve(vrp, 'test')
    assert solution
    assert_equal problem[:services].size + 1,
                 solution.routes.find{ |r| r[:vehicle_id] == problem[:vehicles].last[:id] }.stops.size
    assert_equal 0, solution.unassigned_stops.size
  end

  def test_double_hard_time_windows_problem
    pyvrp = OptimizerWrapper.config[:services][:pyvrp]
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 5, 5],
          [5, 0, 5],
          [5, 5, 0]
        ]
      }],
      points: [{
        id: 'point_0',
        matrix_index: 0
      }, {
        id: 'point_1',
        matrix_index: 1
      }, {
        id: 'point_2',
        matrix_index: 2
      }],
      vehicles: [{
        id: 'vehicle_0',
        start_point_id: 'point_0',
        matrix_id: 'matrix_0'
      }],
      services: [{
        id: 'service_1',
        activity: {
          point_id: 'point_1',
          timewindows: [{
            start: 3,
            end: 4
          }, {
            start: 7,
            end: 8
          }],
          late_multiplier: 0,
        }
      }, {
        id: 'service_2',
        activity: {
          point_id: 'point_2',
          timewindows: [{
            start: 5,
            end: 6
          }, {
            start: 10,
            end: 11
          }],
          late_multiplier: 0,
        }
      }],
      configuration: {
        resolution: {
          duration: 20,
        },
        restitution: {
          intermediate_solutions: false,
        }
      }
    }
    vrp = TestHelper.create(problem)
    solution = pyvrp.solve(vrp, 'test')
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal problem[:services].size, solution.routes.first.stops.count(&:service_id)
  end

  def test_triple_hard_time_windows_problem
    pyvrp = OptimizerWrapper.config[:services][:pyvrp]
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 9, 9],
          [9, 0, 9],
          [9, 9, 0]
        ]
      }],
      points: [{
        id: 'point_0',
        matrix_index: 0
      }, {
        id: 'point_1',
        matrix_index: 1
      }, {
        id: 'point_2',
        matrix_index: 2
      }],
      vehicles: [{
        id: 'vehicle_0',
        start_point_id: 'point_0',
        matrix_id: 'matrix_0'
      }],
      services: [{
        id: 'service_1',
        activity: {
          point_id: 'point_1',
          timewindows: [{
            start: 3,
            end: 4
          }, {
            start: 7,
            end: 8
          }, {
            start: 11,
            end: 12
          }],
          late_multiplier: 0,
        }
      }, {
        id: 'service_2',
        activity: {
          point_id: 'point_2',
          timewindows: [{
            start: 5,
            end: 6
          }, {
            start: 10,
            end: 11
          }, {
            start: 15,
            end: 16
          }],
          late_multiplier: 0,
        }
      }],
      configuration: {
        resolution: {
          duration: 20,
        },
        restitution: {
          intermediate_solutions: false,
        }
      }
    }
    vrp = TestHelper.create(problem)
    solution = pyvrp.solve(vrp, 'test')
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal problem[:services].size, solution.routes.first.stops.count(&:service_id)
  end

  def test_skills
    pyvrp = OptimizerWrapper.config[:services][:pyvrp]
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 3, 3, 3],
          [3, 0, 3, 3],
          [3, 3, 0, 3],
          [3, 3, 3, 0]
        ]
      }],
      points: [{
        id: 'point_0',
        matrix_index: 0
      }, {
        id: 'point_1',
        matrix_index: 1
      }, {
        id: 'point_2',
        matrix_index: 2
      }, {
        id: 'point_3',
        matrix_index: 3
      }],
      vehicles: [{
        id: 'vehicle_0',
        cost_time_multiplier: 1,
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        matrix_id: 'matrix_0',
        skills: [['frozen']]
      }, {
        id: 'vehicle_1',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        matrix_id: 'matrix_0',
        skills: [['cool']]
      }],
      services: [{
        id: 'service_0',
        activity: {
          point_id: 'point_1',
          late_multiplier: 0,
        },
        skills: ['frozen']
      }, {
        id: 'service_1',
        activity: {
          point_id: 'point_2',
          late_multiplier: 0,
        },
        skills: ['cool']
      }, {
        id: 'service_2',
        activity: {
          point_id: 'point_3',
          late_multiplier: 0,
        },
        skills: ['frozen']
      }, {
        id: 'service_3',
        activity: {
          point_id: 'point_3',
          late_multiplier: 0,
        },
        skills: ['cool']
      }],
      configuration: {
        preprocessing: {
          prefer_short_segment: true
        },
        resolution: {
          duration: 1000
        },
        restitution: {
          intermediate_solutions: false,
        }
      }
    }
    vrp = TestHelper.create(problem)
    solution = pyvrp.solve(vrp, 'test')
    assert solution
    assert_equal 4, solution.routes.first.stops.size
    assert_equal 4, solution.routes[1].stops.size
    assert_equal 0, solution.unassigned_stops.size
  end

  def test_setup_duration
    problem = VRP.basic

    problem[:matrices].first[:time] = [
      [0, 4, 0, 5],
      [6, 0, 0, 5],
      [1, 0, 0, 5],
      [5, 5, 5, 0]
    ]

    problem[:services].first[:activity][:timewindows] = [{
      start: 10,
      end: 20
    }]

    problem[:services].each{ |service|
      service[:activity][:setup_duration] = 1
    }

    problem[:services][1][:activity][:timewindows] = [{
      start: 1,
      end: 1
    }]

    problem[:services] << problem[:services][1].dup.tap{ |s| s[:id] = 'service_4' }

    vrp = TestHelper.create(problem)
    solution = @pyvrp.solve(vrp, 'test')
    assert_equal 0, solution.unassigned_stops.size
  end

  def test_reload_depot_with_lat_lon_capacitated
    problem = VRP.lat_lon_capacitated

    problem[:reload_depots] = [{
      id: 'reload_depot_1',
      point_id: 'point_0',
      duration: 300,
      timewindows: [{
        start: 0,
        end: 86400
      }]
    }, {
      id: 'reload_depot_2',
      point_id: 'point_0',
      duration: 300,
      timewindows: [{
        start: 0,
        end: 86400
      }]
    }]

    problem[:vehicles].first[:reload_depot_ids] = ['reload_depot_1', 'reload_depot_2']
    problem[:vehicles].first[:maximum_reloads] = 4 # Only 2 are necessary

    vrp = TestHelper.create(problem)
    solution = @pyvrp.solve(vrp, 'test')

    assert solution
    assert_equal 1, solution.routes.size

    assert_equal vrp.services.size + 4, solution.routes.first.stops.size,
                 'Route should contain all services, 2 depots and 2 reloads'

    assert_equal(
      [3, 6],
      solution.routes.first.stops.size.times.select{ |i| solution.routes.first.stops[i][:type] == :reload_depot },
      'Route should contain 2 reload depots at indices 3 and 6'
    )
  end

  def test_infeasible_reload_keeps_visits_after_depot
    problem = VRP.lat_lon_capacitated
    problem[:reload_depots] = [{
      id: 'reload_depot_1',
      point_id: 'point_0',
      duration: 300,
      timewindows: [{
        start: 0,
        end: 86400
      }]
    }]
    problem[:vehicles].first[:reload_depot_ids] = ['reload_depot_1']
    problem[:vehicles].first[:maximum_reloads] = 2

    vrp = TestHelper.create(problem)
    solver = @pyvrp

    solver.stub(:run_pyvrp, lambda { |_problem, _timeout|
      service_indices =
        solver.instance_variable_get(:@service_index_map).each_with_index.filter_map{ |service, idx|
          idx if service
        }
      reload_index = solver.instance_variable_get(:@reload_depot_hash)['reload_depot_1']
      start_depot = solver.instance_variable_get(:@vehicle_start_point_index_hash)['vehicle_0']
      end_depot = solver.instance_variable_get(:@vehicle_end_point_index_hash)['vehicle_0']
      assert_equal 0, start_depot, 'Regression needs depot index 0 to stay truthy when reading the solution'

      # 6 services of 2kg, capacity 5 → two visits between reloads; combined load exceeds capacity.
      activities = []
      service_indices.each_slice(2).with_index{ |visits, idx|
        visits.each{ |visit_index| activities << { type: 'client', idx: visit_index } }
        last_slice = idx == (service_indices.size / 2) - 1
        activities << { type: 'depot', idx: reload_index } unless last_slice
      }

      {
        runtime: 0.01,
        iterations: 1,
        cost: -1,
        feasible: false,
        complete: true,
        routes: [{
          vehicle_type: 0,
          activities: activities,
          start_depot: start_depot,
          end_depot: end_depot,
          start_time: 0,
          end_time: 1000
        }]
      }
    }) do
      solution = solver.solve(vrp, 'test')

      assert_equal 0, solution.unassigned_stops.size
      assert_equal vrp.services.size, solution.routes.first.stops.count(&:service_id)
      assert_equal :depot, solution.routes.first.stops.first.type
      assert_equal :depot, solution.routes.first.stops.last.type
      assert_equal 2, (solution.routes.first.stops.count { |stop| stop.type == :reload_depot })
    end
  end

  def test_initial_routes_are_sent_as_activities
    problem = VRP.lat_lon_capacitated
    problem[:reload_depots] = [{
      id: 'reload_1',
      point_id: 'point_0'
    }]
    problem[:vehicles].first[:reload_depot_ids] = ['reload_1']
    problem[:vehicles].first[:maximum_reloads] = 4

    vrp = TestHelper.create(problem)
    vehicle = vrp.vehicles.first
    stops = vrp.services.map{ |service| Models::Solution::Stop.new(service) }
    solution = Models::Solution.new(
      routes: [Models::Solution::Route.new(vehicle: vehicle, stops: stops)],
      unassigned_stops: []
    )
    Wrappers::PyVRP.seed_vrp_routes_from_solution(vrp, solution)

    empty_result = { feasible: true, complete: true, routes: [], runtime: 0, cost: 0 }
    @pyvrp.stub(
      :run_pyvrp, lambda{ |payload, _timeout|
        payload[:routes].each{ |route|
          refute route.key?(:trips)
          refute route.key?(:visits)
        }
        types = payload[:routes].first[:activities].map{ |activity| activity[:type] }
        assert_includes types, 'client'
        assert_includes types, 'depot'
        empty_result
      }
    ) do
      @pyvrp.solve(vrp)
    end
  end

  def test_solve_params_enable_group_ops_and_scale_neighbourhood
    require 'open3'

    python = @pyvrp.send(:pyvrp_python)
    script = <<~'PY'
      import sys
      sys.path.insert(0, '.')
      from wrappers.pyvrp_wrapper import build_solve_params

      small = build_solve_params(10)
      assert small.neighbourhood.num_neighbours == 50, small.neighbourhood.num_neighbours
      medium = build_solve_params(499)
      assert medium.neighbourhood.num_neighbours == 100, medium.neighbourhood.num_neighbours
      assert medium.penalty.max_penalty == 1_000_000.0, medium.penalty.max_penalty
      large = build_solve_params(3568)
      assert large.neighbourhood.num_neighbours == 150, large.neighbourhood.num_neighbours
      assert small.penalty.max_penalty == 100_000.0, small.penalty.max_penalty
      assert large.penalty.max_penalty == 1_000_000.0, large.penalty.max_penalty

      class FakeData:
          num_load_dimensions = 3

      loads, duration, distance = medium.penalty.midpoint_penalties(FakeData())
      assert loads == [10.0, 10.0, 10.0], loads
      assert duration == 10.0, duration
      assert distance == 10.0, distance
      names = [op.__name__ for op in large.operators]
      for expected in ('RelocateAlternative', 'ReplaceGroup', 'RelocateWithDepot', 'RemoveAdjacentDepot'):
          assert expected in names, names
      print('ok')
    PY

    stdout, stderr, status = Open3.capture3(python, '-c', script, chdir: File.expand_path('../..', __dir__))
    assert status.success?, "#{stderr}\n#{stdout}"
    assert_includes stdout, 'ok'
  end

  def test_problem_data_accepts_multi_tw_groups_with_depot_offset_clients
    require 'open3'

    python = @pyvrp.send(:pyvrp_python)
    script = <<~'PY'
      import sys
      sys.path.insert(0, '.')
      from wrappers.pyvrp_wrapper import ProblemData

      payload = {
          "depots": [{"x": 0, "y": 0, "name": "d0"}],
          "clients": [
              {"x": 1, "y": 1, "group": 0, "required": False, "name": "s0_tw0"},
              {"x": 1, "y": 1, "group": 0, "required": False, "name": "s0_tw1"},
          ],
          "vehicle_types": [{"num_available": 1, "start_depot": 0, "end_depot": 0}],
          "distance_matrices": [[[0, 1, 1], [1, 0, 0], [1, 0, 0]]],
          "duration_matrices": [[[0, 1, 1], [1, 0, 0], [1, 0, 0]]],
          "groups": [{"clients": [1, 2], "required": True}],
      }
      data = ProblemData.from_dict(payload)
      assert data.num_clients == 2, data.num_clients
      assert data.num_groups == 1, data.num_groups
      assert list(data.group(0).clients) == [0, 1], list(data.group(0).clients)
      print('ok')
    PY

    stdout, stderr, status = Open3.capture3(python, '-c', script, chdir: File.expand_path('../..', __dir__))
    assert status.success?, "#{stderr}\n#{stdout}"
    assert_includes stdout, 'ok'
  end

  def test_solution_serializes_inner_activities
    require 'open3'

    python = @pyvrp.send(:pyvrp_python)
    script = <<~'PY'
      import sys
      sys.path.insert(0, '.')
      from wrappers.pyvrp_wrapper import (
          ProblemData,
          Route,
          Activity,
          ActivityType,
          _inner_route_activities,
          _activity_to_dict,
      )

      payload = {
          "depots": [
              {"x": 0, "y": 0, "name": "start"},
              {"x": 2, "y": 2, "name": "reload"},
          ],
          "clients": [{"x": 1, "y": 1, "name": "c0"}],
          "vehicle_types": [{
              "num_available": 1,
              "start_depot": 0,
              "end_depot": 0,
              "reload_depots": [1],
              "max_reloads": 2,
          }],
          "distance_matrices": [[[0, 1, 1], [1, 0, 1], [1, 1, 0]]],
          "duration_matrices": [[[0, 1, 1], [1, 0, 1], [1, 1, 0]]],
      }
      data = ProblemData.from_dict(payload)
      route = Route(
          data,
          activities=[
              Activity(ActivityType.CLIENT, 0),
              Activity(ActivityType.DEPOT, 1),
          ],
          vehicle_type=0,
      )
      inner = [_activity_to_dict(activity) for activity in _inner_route_activities(route)]
      assert [(item["type"], item["idx"]) for item in inner] == [
          ("client", 0),
          ("depot", 1),
      ], inner
      print('ok')
    PY

    stdout, stderr, status = Open3.capture3(python, '-c', script, chdir: File.expand_path('../..', __dir__))
    assert status.success?, "#{stderr}\n#{stdout}"
    assert_includes stdout, 'ok'
  end
end
