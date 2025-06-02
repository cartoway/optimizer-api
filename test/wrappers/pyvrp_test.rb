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

  def test_partially_nil_capacities
    problem = VRP.basic
    problem[:services].each{ |service|
      service[:quantities] = [{ unit_id: 'kg', value: 1 }]
    }
    problem[:vehicles] << problem[:vehicles].first.dup
    problem[:vehicles].first[:capacities] = [{ unit_id: 'kg', limit: 2 }]
    problem[:vehicles].last[:id] = 'vehicle_1'

    pyvrp = Wrappers::PyVRP.new
    pyvrp.stub(
      :run_pyvrp, lambda{ |pyvrp_vrp, _job|
        assert_equal [2 * Wrappers::PyVRP::CUSTOM_QUANTITY_BIGNUM], pyvrp_vrp[:vehicles].first[:capacity]
        assert_equal pyvrp_vrp[:jobs].flat_map{ |job| job[:pickup].first }.sum,
                     pyvrp_vrp[:vehicles].last[:capacity].first
        nil
      }
    ) do
      @pyvrp.solve(TestHelper.create(problem))
    end
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
    assert_equal problem[:services].size, solution.routes.first.stops.size
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
    assert_equal problem[:services].size, solution.routes.first.stops.size
  end
end
