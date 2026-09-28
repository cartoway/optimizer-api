require './test/test_helper'

class Wrappers::RosomaxaTest < Minitest::Test
  def setup
    @rosomaxa = OptimizerWrapper.config[:services][:rosomaxa]
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
        ],
        distance: [
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
      configuration: {
        resolution: {
          duration: 1000
        }
      }
    }
  end

  def test_minimal_problem
    vrp = TestHelper.create(@minimal_problem)
    solution = @rosomaxa.solve(vrp)

    assert solution
    assert_includes solution.solvers, :rosomaxa
    assert_equal 1, solution.routes.size
    assert_equal @minimal_problem[:services].size + 1, solution.routes.first.stops.size
    assert_equal @minimal_problem[:services].collect{ |service| service[:id] }.sort,
                 solution.routes.first.stops.filter_map(&:service_id).sort
  end

  def test_loop_problem
    vrp = TestHelper.create(@problem)
    solution = @rosomaxa.solve(vrp)

    assert solution
    assert_includes solution.solvers, :rosomaxa
    assert_equal 1, solution.routes.size
    assert_equal @problem[:services].size + 2, solution.routes.first.stops.size
    assert_equal @problem[:services].collect{ |service| service[:id] }.sort,
                 solution.routes.first.stops.filter_map(&:service_id).sort
  end

  def test_capacity_leaves_one_service_unassigned
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 10, 10],
          [10, 0, 10],
          [10, 10, 0]
        ],
        distance: [
          [0, 10, 10],
          [10, 0, 10],
          [10, 10, 0]
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
      units: [{ id: 'kg' }],
      vehicles: [{
        id: 'vehicle_0',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        matrix_id: 'matrix_0',
        capacities: [{ unit_id: 'kg', limit: 1 }]
      }],
      services: [{
        id: 'service_1',
        quantities: [{ unit_id: 'kg', delivery: 1 }],
        activity: { point_id: 'point_1' }
      }, {
        id: 'service_2',
        quantities: [{ unit_id: 'kg', delivery: 1 }],
        activity: { point_id: 'point_2' }
      }],
      configuration: {
        resolution: {
          duration: 1000
        }
      }
    }
    vrp = TestHelper.create(problem)
    solution = @rosomaxa.solve(vrp)

    assert solution
    assert_includes solution.solvers, :rosomaxa
    assigned = solution.routes.flat_map{ |route| route.stops.filter_map(&:service_id) }
    assert_equal 1, assigned.size
    assert_equal 1, solution.unassigned_stops.count(&:service_id)
  end

  def test_relation_is_inapplicable
    vrp = TestHelper.create(
      @minimal_problem.merge(
        relations: [{
          type: :order,
          linked_ids: ['service_0', 'service_1']
        }]
      )
    )

    assert_includes @rosomaxa.inapplicable_solve?(vrp), :assert_no_relations_except_simple_shipments
  end

  def test_shipment_pickup_before_delivery
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [[0, 10, 10], [10, 0, 10], [10, 10, 0]],
        distance: [[0, 10, 10], [10, 0, 10], [10, 10, 0]]
      }],
      points: [
        { id: 'point_0', matrix_index: 0 },
        { id: 'point_1', matrix_index: 1 },
        { id: 'point_2', matrix_index: 2 }
      ],
      units: [{ id: 'kg' }],
      vehicles: [{
        id: 'vehicle_0',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        matrix_id: 'matrix_0',
        capacities: [{ unit_id: 'kg', limit: 5 }]
      }],
      services: [{
        id: 'pickup_1',
        quantities: [{ unit_id: 'kg', value: 1 }],
        activity: { point_id: 'point_1' }
      }, {
        id: 'delivery_1',
        quantities: [{ unit_id: 'kg', value: -1 }],
        activity: { point_id: 'point_2' }
      }],
      relations: [{
        id: 'ship_1',
        type: :shipment,
        linked_ids: ['pickup_1', 'delivery_1']
      }],
      configuration: { resolution: { duration: 1000 } }
    }
    vrp = TestHelper.create(problem)
    assert_empty @rosomaxa.inapplicable_solve?(vrp)

    solution = @rosomaxa.solve(vrp)
    ids = solution.routes.first.stops.filter_map(&:service_id)
    assert_equal %w[pickup_1 delivery_1], ids
  end

  def test_reload_serves_both_deliveries
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [[0, 10, 10], [10, 0, 10], [10, 10, 0]],
        distance: [[0, 10, 10], [10, 0, 10], [10, 10, 0]]
      }],
      points: [
        { id: 'point_0', matrix_index: 0 },
        { id: 'point_1', matrix_index: 1 },
        { id: 'point_2', matrix_index: 2 }
      ],
      units: [{ id: 'kg' }],
      reload_depots: [{ id: 'reload_1', point_id: 'point_0', duration: 1 }],
      vehicles: [{
        id: 'vehicle_0',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        matrix_id: 'matrix_0',
        capacities: [{ unit_id: 'kg', limit: 1 }],
        reload_depot_ids: ['reload_1'],
        maximum_reloads: 2
      }],
      services: [{
        id: 'service_1',
        quantities: [{ unit_id: 'kg', delivery: 1 }],
        activity: { point_id: 'point_1' }
      }, {
        id: 'service_2',
        quantities: [{ unit_id: 'kg', delivery: 1 }],
        activity: { point_id: 'point_2' }
      }],
      configuration: { resolution: { duration: 1000 } }
    }
    vrp = TestHelper.create(problem)
    solution = @rosomaxa.solve(vrp)

    assigned = solution.routes.flat_map{ |route| route.stops.filter_map(&:service_id) }
    assert_equal %w[service_1 service_2], assigned.sort
    assert(solution.routes.first.stops.any?{ |stop| stop.type == :reload_depot })
  end

  def test_lunch_break_is_scheduled
    problem = @minimal_problem.dup
    problem[:rests] = [{
      id: 'lunch',
      duration: 5,
      timewindows: [{ start: 0, end: 3600 }]
    }]
    problem[:vehicles] = [{
      id: 'vehicle_0',
      start_point_id: 'point_0',
      matrix_id: 'matrix_0',
      rest_ids: ['lunch'],
      timewindow: { start: 0, end: 3600 }
    }]
    vrp = TestHelper.create(problem)
    assert_empty @rosomaxa.inapplicable_solve?(vrp)

    solution = @rosomaxa.solve(vrp)
    assert(solution.routes.first.stops.any?{ |stop| stop.type == :rest && stop.rest_id == 'lunch' })
  end

  def test_regulatory_rest_is_inapplicable
    problem = @minimal_problem.dup
    problem[:rests] = [{ id: 'reg_rest', duration: 10, lapse: 100 }]
    problem[:vehicles] = [{
      id: 'vehicle_0',
      start_point_id: 'point_0',
      matrix_id: 'matrix_0',
      rest_ids: ['reg_rest']
    }]
    vrp = TestHelper.create(problem)

    assert_includes @rosomaxa.inapplicable_solve?(vrp), :assert_only_simple_rests
  end

  def test_setup_duration_is_added_to_incoming_travel
    problem = @minimal_problem.dup
    problem[:services] = [{
      id: 'service_0',
      activity: { point_id: 'point_0' }
    }, {
      id: 'service_1',
      activity: { point_id: 'point_1', setup_duration: 7 }
    }]
    problem[:vehicles] = [{
      id: 'vehicle_0',
      start_point_id: 'point_0',
      matrix_id: 'matrix_0',
      coef_setup: 2
    }]
    vrp = TestHelper.create(problem)
    assert_empty @rosomaxa.inapplicable_solve?(vrp)

    _problem, matrices = @rosomaxa.send(:pragmatic_problem, vrp)
    assert_equal [0, 15, 1, 0], matrices.first[:travelTimes]

    solution = @rosomaxa.solve(vrp)
    visit = solution.routes.first.stops.find{ |stop| stop.service_id == 'service_1' }
    assert visit.info.begin_time >= 15
  end

  def test_different_setup_durations_on_one_point_are_inapplicable
    problem = @minimal_problem.dup
    problem[:services] = [{
      id: 'service_a',
      activity: { point_id: 'point_1', setup_duration: 5 }
    }, {
      id: 'service_b',
      activity: { point_id: 'point_1', setup_duration: 9 }
    }]
    vrp = TestHelper.create(problem)

    assert_includes @rosomaxa.inapplicable_solve?(vrp), :assert_no_complex_setup_durations
  end

  def test_vehicle_without_start_is_inapplicable
    problem = @minimal_problem.dup
    problem[:vehicles] = [{
      id: 'vehicle_0',
      end_point_id: 'point_0',
      matrix_id: 'matrix_0'
    }]
    vrp = TestHelper.create(problem)

    assert_includes @rosomaxa.inapplicable_solve?(vrp), :assert_vehicles_have_start
  end
end
