# Copyright © Mapotempo, 2016
#
# This file is part of Mapotempo.
#
# Mapotempo is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Mapotempo is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Mapotempo. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#
require './test/test_helper'

class Wrappers::VroomTest < Minitest::Test
  def setup
    @vroom = OptimizerWrapper.config[:services][:vroom]
    @minimal_problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
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
    }
    @problem = problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
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

    solution = @vroom.solve(vrp)

    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @minimal_problem[:services].size + 1, solution.routes.first.stops.size
  end

  def test_loop_problem

    vrp = TestHelper.create(@problem)
    solution = @vroom.solve(vrp)
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @problem[:services].size + 2, solution.routes.first.stops.size
    assert_equal @problem[:services].collect{ |s| s[:id] }.sort!, solution.routes.first.stops[1..-2].map(&:id).sort!
  end

  def test_no_end_problem
    @problem[:vehicles][0].delete(:end_point_id)
    vrp = TestHelper.create(@problem)
    solution = @vroom.solve(vrp)
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @problem[:services].size + 1, solution.routes.first.stops.size
    assert_equal @problem[:services].collect{ |s| s[:id] }.sort!, solution.routes.first.stops[1..-1].map(&:id).sort!
  end

  def test_start_different_end_problem
    @problem[:vehicles][0][:end_point_id] = 'point_4'
    vrp = TestHelper.create(@problem)
    solution = @vroom.solve(vrp)
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
    solution = @vroom.solve(vrp)
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @minimal_problem[:services].size + 1, solution.routes.first.stops.size
  end

  def test_with_rest
    @problem[:vehicles][0][:rest_ids] = ['rest_a']
    @problem[:rests] = [{
      id: 'rest_a',
      timewindows: [{
        start: 9000,
        end: 10000
      }],
      duration: 1000
    }]
    @problem[:vehicles][0][:timewindow] = {
      start: 100, end: 20000
    }
    @problem[:services].each.with_index{ |service, index|
      service[:activity][:point_id] = "point_#{@problem[:points].size - 1 - index}"
    }
    vrp = TestHelper.create(@problem)
    solution = @vroom.solve(vrp)
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @problem[:services].size + 2 + @problem[:vehicles][0][:rest_ids].size, solution.routes.first.stops.size
    stops = solution.routes.first.stops[1..-2].map(&:service_id)
    stops.compact!
    assert_equal @problem[:services].collect{ |s| s[:id] }.sort!, stops.sort!
    assert_equal(3, solution.routes[0][:stops].index{ |a| a[:rest_id] })
  end

  def test_with_rest_at_the_end
    @problem[:vehicles][0][:rest_ids] = ['rest_a']
    @problem[:rests] = [{
      id: 'rest_a',
      timewindows: [{
        start: 19000,
        end: 20000
      }],
      duration: 1000
    }]
    @problem[:vehicles][0][:timewindow] = {
      start: 100, end: 20000
    }
    @problem[:services].each.with_index{ |service, index|
      service[:activity][:point_id] = "point_#{@problem[:points].size - 1 - index}"
    }
    vrp = TestHelper.create(@problem)
    solution = @vroom.solve(vrp)
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @problem[:services].size + 2 + @problem[:vehicles][0][:rest_ids].size, solution.routes.first.stops.size
    stops = solution.routes.first.stops[1..-2].map(&:service_id)
    stops.compact!
    assert_equal @problem[:services].collect{ |s| s[:id] }.sort!, stops.sort!
    assert_equal 5, solution.routes.first.stops.index(&:rest_id)
  end

  def test_with_rest_at_the_start
    @problem[:rests] = [{
      id: 'rest_a',
      timewindows: [{
        start: 200,
        end: 500
      }],
      duration: 1000
    }]
    @problem[:vehicles][0][:rest_ids] = ['rest_a']
    vrp = TestHelper.create(@problem)
    solution = @vroom.solve(vrp)
    assert solution
    assert_equal 1, solution.routes.size
    assert_equal @problem[:services].size + 2 + @problem[:vehicles][0][:rest_ids].size,
                 solution.routes.first.stops.size
    stops = solution.routes.first.stops[1..-2].map(&:service_id)
    stops.compact!
    assert_equal @problem[:services].collect{ |s| s[:id] }.sort!, stops.sort!
    assert_equal 1, solution.routes.first.stops.index(&:rest_id)
  end

  def test_vroom_with_self_selection
    vrp = VRP.basic
    vrp[:configuration][:preprocessing][:first_solution_strategy] = ['self_selection']

    vroom_counter = 0
    OptimizerWrapper.config[:services][:vroom].stub(
      :solve,
      lambda { |vrp_in, _job, _thread_prod|
        vroom_counter += 1
        # Return empty result to make sure the code continues regularly
        Models::Solution.new(
          solvers: [:vroom],
          unassigned_stops: vrp_in.services.map{ |service| Models::Solution::Stop.new(service) }
        )
      }
    ) do
      OptimizerWrapper.wrapper_vrp('vroom', { services: { vrp: [:vroom] }}, TestHelper.create(vrp), nil)
    end
    assert_equal 1, vroom_counter
  end

  def test_ensure_total_time_and_travel_info_with_vroom
    vrp = VRP.basic
    vrp[:matrices].first[:distance] = vrp[:matrices].first[:time]
    solutions = OptimizerWrapper.wrapper_vrp('vroom', { services: { vrp: [:vroom] }}, TestHelper.create(vrp), nil)
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

  def test_shipments
    vrp = TestHelper.create(VRP.pud)
    solution = @vroom.solve(vrp, 'test')
    assert solution
    assert solution.routes.first.stops.index{ |activity| activity.pickup_shipment_id == 'shipment_0' } <
           solution.routes.first.stops.index{ |activity| activity.delivery_shipment_id == 'shipment_0' }
    assert solution.routes.first.stops.index{ |activity| activity.pickup_shipment_id == 'shipment_1' } <
           solution.routes.first.stops.index{ |activity| activity.delivery_shipment_id == 'shipment_1' }
    assert_equal 0, solution.unassigned_stops.size
    assert_equal 6, solution.routes.first.stops.size
  end

  def test_shipments_timewindows
    problem = VRP.pud
    problem[:shipments].map!{ |shipment|
      shipment[:pickup][:timewindows] = [{start: 5, end: 20}]
      shipment[:delivery][:timewindows] = [{start: 10, end: 40}]
      shipment
    }

    vrp = TestHelper.create(problem)
    solution = @vroom.solve(vrp, 'test')
    assert solution
    assert solution.routes.first.stops.index{ |activity| activity.pickup_shipment_id == 'shipment_0' } <
           solution.routes.first.stops.index{ |activity| activity.delivery_shipment_id == 'shipment_0' }
    assert solution.routes.first.stops.index{ |activity| activity.pickup_shipment_id == 'shipment_1' } <
           solution.routes.first.stops.index{ |activity| activity.delivery_shipment_id == 'shipment_1' }
    assert_equal 0, solution.unassigned_stops.size
    assert_equal 6, solution.routes.first.stops.size
  end

  def test_shipments_quantities
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 3, 3],
          [3, 0, 3],
          [3, 3, 0]
        ]
      }],
      units: [{
        id: 'unit_0',
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
        cost_time_multiplier: 1,
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        matrix_id: 'matrix_0',
        capacities: [{
          unit_id: 'unit_0',
          limit: 2
        }]
      }],
      shipments: [{
        id: 'shipment_0',
        pickup: {
          point_id: 'point_1',
          duration: 3,
          late_multiplier: 0,
        },
        delivery: {
          point_id: 'point_2',
          duration: 3,
          late_multiplier: 0,
        },
        quantities: [{
          unit_id: 'unit_0',
          value: 2
        }]
      }, {
        id: 'shipment_1',
        pickup: {
          point_id: 'point_1',
          duration: 3,
          late_multiplier: 0,
        },
        delivery: {
          point_id: 'point_2',
          duration: 3,
          late_multiplier: 0,
        },
        quantities: [{
          unit_id: 'unit_0',
          value: 2
        }]
      }],
      configuration: {
        preprocessing: {
          prefer_short_segment: true
        },
        resolution: {
          duration: 100
        },
        restitution: {
          intermediate_solutions: false,
        }
      }
    }
    vrp = TestHelper.create(problem)
    solution = @vroom.solve(vrp, 'test')
    assert solution
    assert_equal(solution.routes.first.stops.index{ |activity| activity.pickup_shipment_id == 'shipment_0' } + 1,
                 solution.routes.first.stops.index{ |activity| activity.delivery_shipment_id == 'shipment_0' })
    assert_equal(solution.routes.first.stops.index{ |activity| activity.pickup_shipment_id == 'shipment_1' } + 1,
                 solution.routes.first.stops.index{ |activity| activity.delivery_shipment_id == 'shipment_1' })
    assert_equal 0, solution.unassigned_stops.size
    assert_equal 6, solution.routes.first.stops.size
  end

  def test_mixed_shipments_and_services
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 1, 1, 1],
          [1, 0, 1, 1],
          [1, 1, 0, 1],
          [1, 1, 1, 0]
        ]
      }],
      units: [{
        id: 'unit_0',
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
        matrix_id: 'matrix_0'
      }],
      services: [{
        id: 'service_1',
        activity: {
          point_id: 'point_1',
        },
        quantities: [{
          unit_id: 'unit_0',
          setup_value: 1,
        }]
      }],
      shipments: [{
        id: 'shipment_1',
        pickup: {
          point_id: 'point_2',
          duration: 1,
          late_multiplier: 0,
        },
        delivery: {
          point_id: 'point_3',
          duration: 1,
          late_multiplier: 0,
        }
      }],
      configuration: {
        preprocessing: {
          prefer_short_segment: true
        },
        resolution: {
          duration: 100
        },
        restitution: {
          intermediate_solutions: false,
        }
      }
    }
    vrp = TestHelper.create(problem)
    solution = @vroom.solve(vrp, 'test')
    assert solution
    assert solution.routes.first.stops.index{ |activity| activity.pickup_shipment_id == 'shipment_1' } <
           solution.routes.first.stops.index{ |activity| activity.delivery_shipment_id == 'shipment_1' }
    assert_equal 0, solution.unassigned_stops.size
    assert_equal 5, solution.routes.first.stops.size
  end

  def test_correct_route_collection
    problem = VRP.lat_lon_two_vehicles
    problem[:services].each{ |service|
      service[:skills] = ['s1']
    }
    problem[:vehicles].last[:skills] = [['s1']]

    solutions = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:vroom] }}, TestHelper.create(problem), nil)
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

    solutions = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:vroom] }}, TestHelper.create(problem), nil)
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

    solutions = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:vroom] }}, TestHelper.create(problem), nil)
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

    solutions = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:vroom] }}, TestHelper.create(problem), nil)
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
    OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:vroom] }}, TestHelper.create(problem), nil)
  end

  def test_collect_vehicles_force_start_accepts_string_shift_preference
    problem = @minimal_problem.deep_dup
    problem[:vehicles] = [{
      id: 'vehicle_0',
      start_point_id: 'point_0',
      end_point_id: 'point_0',
      matrix_id: 'matrix_0',
      shift_preference: 'force_start',
      timewindow: { start: 55, end: 500 }
    }]
    vrp = TestHelper.create(problem)
    vroom = Wrappers::Vroom.new
    vroom.send(:rest_equivalence, vrp)
    vroom.instance_variable_set(:@total_quantities, Hash.new(0))
    vehicles_payload = vroom.send(:collect_vehicles, vrp, [], [])
    assert_equal 55, vehicles_payload.first[:departure],
                 'String shift_preference must set VROOM departure (e.g. after dicho partial VRP rebuild)'
    vrp.vehicles.first[:shift_preference] = :force_start
    vehicles_payload_sym = vroom.send(:collect_vehicles, vrp, [], [])
    assert_equal 55, vehicles_payload_sym.first[:departure]
  end

  def test_jobs_pickup_delivery_aligned_with_vehicle_capacity
    problem = VRP.basic
    problem[:units] << { id: 'l' }
    problem[:services].each{ |service|
      service[:quantities] = [
        { unit_id: 'kg', delivery: 1 },
        { unit_id: 'l', pickup: 2 }
      ]
    }
    # Only kg has a vehicle capacity; l is declared on services but excluded from vrp_units.
    problem[:vehicles].each{ |vehicle|
      vehicle[:capacities] = [{ unit_id: 'kg', limit: 3 }]
    }

    vroom = Wrappers::Vroom.new
    vroom.stub(
      :run_vroom, lambda{ |vroom_vrp, _job|
        capacity_size = vroom_vrp[:vehicles].first[:capacity].size
        vroom_vrp[:jobs].each{ |job|
          assert_equal capacity_size, job[:delivery].size
          assert_equal capacity_size, job[:pickup].size
        }
        nil
      }
    ) do
      @vroom.solve(TestHelper.create(problem))
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

    vroom = Wrappers::Vroom.new
    vroom.stub(
      :run_vroom, lambda{ |vroom_vrp, _job|
        assert_equal [2 * Wrappers::Vroom::CUSTOM_QUANTITY_BIGNUM], vroom_vrp[:vehicles].first[:capacity]
        assert_equal vroom_vrp[:jobs].flat_map{ |job| job[:pickup].first }.sum,
                     vroom_vrp[:vehicles].last[:capacity].first
        nil
      }
    ) do
      @vroom.solve(TestHelper.create(problem))
    end
  end

  def test_setup_duration
    problem = VRP.basic

    problem[:matrices].first[:time] = [
      [0, 4, 0, 5],
      [6, 0, 0, 5],
      [1, 0, 0, 5],
      [5, 5, 5, 0]
    ]

    problem[:services] << problem[:services].first.dup.tap{ |s| s[:id] = 'service_4' }
    problem[:services].first[:activity][:timewindows] = [{
      start: 10,
      end: 20
    }]
    problem[:services][1][:activity][:timewindows] = [{
      start: 1,
      end: 1
    }]
    problem[:services].each{ |service|
      service[:activity][:setup_duration] = 1
    }
    vrp = TestHelper.create(problem)
    solution = @vroom.solve(vrp, 'test')
    act_s_one = solution.routes.first.stops.find{ |act| act.service_id == 'service_1' }
    act_s_two = solution.routes.first.stops.find{ |act| act.service_id == 'service_2' }
    assert_equal 10, act_s_one.info.begin_time
    assert_equal 1, act_s_two.info.begin_time
  end

  def test_multiple_matrices
    problem = VRP.lat_lon_two_vehicles
    problem[:matrices] << problem[:matrices].first.dup
    problem[:matrices].last[:id] = 'matrix_1'
    problem[:matrices].last[:time] = problem[:matrices].first[:time]

    vrp = TestHelper.create(problem)
    assert @vroom.solve(vrp, 'test')
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
    assert @vroom.solve(vrp, 'test')
  end

  def test_vehicle_max_distance
    problem = VRP.basic_max_distance
    problem[:vehicles].first[:distance] = 0
    vrp = TestHelper.create(problem)
    solution = @vroom.solve(vrp, 'test')
    assert solution
    assert_equal problem[:services].size + 1,
                 solution.routes.find{ |r| r[:vehicle_id] == problem[:vehicles].last[:id] }.stops.size
    assert_equal 0, solution.unassigned_stops.size
  end

  def test_deform_matrix_skips_depot_legs
    matrix = Models::Matrix.new(
      time: [
        [0, 10, 20],
        [10, 0, 30],
        [20, 30, 0]
      ]
    )
    group = {
      maximum_ride_time: 5,
      maximum_ride_distance: nil,
      ride_time_penalty: 100,
      ride_distance_penalty: nil,
      depot_indices: Set[0]
    }

    deformed = @vroom.send(:deform_matrix_for_ride_constraints, matrix, group)

    assert_equal 10, deformed.time[0][1]
    assert_equal 100, deformed.time[1][2]
  end

  def test_deform_matrix_inflates_inter_job_leg
    matrix = Models::Matrix.new(
      time: [
        [0, 10, 20],
        [10, 0, 30],
        [20, 30, 0]
      ],
      distance: [
        [0, 100, 200],
        [100, 0, 300],
        [200, 300, 0]
      ]
    )
    group = {
      maximum_ride_time: nil,
      maximum_ride_distance: 150,
      deform_distance: false,
      ride_time_penalty: 100,
      ride_distance_penalty: 1_000,
      depot_indices: Set[0],
      max_end: 1_000
    }

    deformed = @vroom.send(:deform_matrix_for_ride_constraints, matrix, group)

    assert_equal 200, deformed.distance[0][2]
    assert_equal 300, deformed.distance[1][2]
    assert_equal 10, deformed.time[0][1]
    assert_equal 1_000, deformed.time[1][2]
  end

  def test_deform_matrix_inflates_distance_when_distance_cost
    matrix = Models::Matrix.new(
      time: [
        [0, 10, 20],
        [10, 0, 30],
        [20, 30, 0]
      ],
      distance: [
        [0, 100, 200],
        [100, 0, 300],
        [200, 300, 0]
      ]
    )
    group = {
      maximum_ride_time: nil,
      maximum_ride_distance: 150,
      deform_distance: true,
      ride_time_penalty: 100,
      ride_distance_penalty: 1_000,
      depot_indices: Set[0],
      max_end: 1_000
    }

    deformed = @vroom.send(:deform_matrix_for_ride_constraints, matrix, group)

    assert_equal 1_000, deformed.distance[1][2]
    assert_equal 1_000, deformed.time[1][2]
  end

  def test_ride_matrix_profiles_shared_across_vehicles
    problem = VRP.lat_lon_two_vehicles
    problem[:vehicles].each{ |vehicle|
      vehicle[:maximum_ride_time] = 600
      vehicle[:matrix_id] = 'm1'
    }
    vrp = TestHelper.create(problem)
    profiles = @vroom.send(:build_vroom_matrix_profiles, vrp, 2**20)

    profile_ids = vrp.vehicles.map{ |vehicle| @vroom.instance_variable_get(:@vehicle_profile_by_id)[vehicle.id] }

    assert_equal 1, profile_ids.uniq.size
    refute_equal 'mm1', profile_ids.first
    assert profiles[profile_ids.first][:durations]
  end

  def test_ride_matrix_profiles_split_on_different_max_ride
    problem = VRP.lat_lon_two_vehicles
    problem[:vehicles].first[:maximum_ride_time] = 600
    problem[:vehicles].last[:maximum_ride_time] = 1_200
    problem[:vehicles].each{ |vehicle| vehicle[:matrix_id] = 'm1' }
    vrp = TestHelper.create(problem)
    @vroom.send(:build_vroom_matrix_profiles, vrp, 2**20)

    profile_ids = vrp.vehicles.map{ |vehicle| @vroom.instance_variable_get(:@vehicle_profile_by_id)[vehicle.id] }

    assert_equal 2, profile_ids.uniq.size
  end

  def test_vroom_problem_deforms_matrix_for_maximum_ride_time
    problem = VRP.basic
    problem[:vehicles].first[:maximum_ride_time] = 3
    vrp = TestHelper.create(problem)
    problem_json = @vroom.send(:vroom_problem, vrp, [:time, :distance])
    profile = problem_json[:vehicles].first[:profile]
    durations = problem_json[:matrices][profile][:durations]

    assert_equal 1, durations[1][2]
    assert_operator durations[2][3], :>, 5
    assert_equal 6, durations[1][0]
  end

  def test_vroom_problem_deforms_matrix_for_maximum_ride_distance
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 4, 5, 5],
          [6, 0, 1, 5],
          [1, 2, 0, 5],
          [5, 5, 5, 0]
        ],
        distance: [
          [0, 100, 3, 3],
          [100, 0, 1000, 1000],
          [3, 1000, 0, 3],
          [3, 1000, 3, 0]
        ]
      }],
      points: (0..3).map { |i| { id: "point_#{i}", matrix_index: i } },
      vehicles: [{
        id: 'vehicle_0',
        matrix_id: 'matrix_0',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        cost_time_multiplier: 1,
        cost_distance_multiplier: 0,
        maximum_ride_distance: 4
      }],
      services: (1..3).map { |i|
        { id: "service_#{i}", activity: { point_id: "point_#{i}" } }
      },
      configuration: {
        resolution: { duration: 100 },
        restitution: { intermediate_solutions: false }
      }
    }
    vrp = TestHelper.create(problem)
    problem_json = @vroom.send(:vroom_problem, vrp, [:time, :distance])
    profile = problem_json[:vehicles].first[:profile]
    durations = problem_json[:matrices][profile][:durations]
    distances = problem_json[:matrices][profile][:distances]

    assert_equal 6, durations[1][0]
    assert_operator durations[1][2], :>, 5
    assert_equal 1000, distances[1][2]
  end

  def test_vroom_problem_deforms_distance_for_maximum_ride_distance_when_distance_cost
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 4, 5, 5],
          [6, 0, 1, 5],
          [1, 2, 0, 5],
          [5, 5, 5, 0]
        ],
        distance: [
          [0, 100, 3, 3],
          [100, 0, 1000, 1000],
          [3, 1000, 0, 3],
          [3, 1000, 3, 0]
        ]
      }],
      points: (0..3).map { |i| { id: "point_#{i}", matrix_index: i } },
      vehicles: [{
        id: 'vehicle_0',
        matrix_id: 'matrix_0',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        cost_time_multiplier: 0,
        cost_distance_multiplier: 1,
        maximum_ride_distance: 4
      }],
      services: (1..3).map { |i|
        { id: "service_#{i}", activity: { point_id: "point_#{i}" } }
      },
      configuration: {
        resolution: { duration: 100 },
        restitution: { intermediate_solutions: false }
      }
    }
    vrp = TestHelper.create(problem)
    problem_json = @vroom.send(:vroom_problem, vrp, [:time, :distance])
    profile = problem_json[:vehicles].first[:profile]
    distances = problem_json[:matrices][profile][:distances]

    assert_operator distances[1][2], :>, 100
  end

  def test_maximum_ride_distance_with_vroom_solver_multi_vehicle
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 1000, 1, 1],
          [1000, 0, 1000, 1000],
          [1, 1000, 0, 1],
          [1, 1000, 1, 0]
        ],
        distance: [
          [0, 1000, 3, 3],
          [1000, 0, 1000, 1000],
          [3, 1000, 0, 3],
          [3, 1000, 3, 0]
        ]
      }],
      points: (0..3).map { |i| { id: "point_#{i}", matrix_index: i } },
      vehicles: [{
        id: 'vehicle_0',
        matrix_id: 'matrix_0',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        cost_time_multiplier: 1,
        cost_distance_multiplier: 0,
        maximum_ride_distance: 4
      }, {
        id: 'vehicle_1',
        matrix_id: 'matrix_0',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        cost_time_multiplier: 1,
        cost_distance_multiplier: 0,
        maximum_ride_distance: 4
      }],
      services: (1..3).map { |i|
        { id: "service_#{i}", activity: { point_id: "point_#{i}" } }
      },
      configuration: {
        resolution: { duration: 30_000 },
        restitution: { intermediate_solutions: false }
      }
    }
    vrp = TestHelper.create(problem)

    refute_includes OptimizerWrapper.config[:services][:vroom].inapplicable_solve?(vrp),
                    :assert_no_ride_constraint

    problem_json = @vroom.send(:vroom_problem, vrp, [:time, :distance])
    profile = problem_json[:vehicles].first[:profile]
    assert_operator problem_json[:matrices][profile][:durations][1][2], :>, 1000
    refute problem_json[:vehicles].first[:costs].key?(:per_km)

    solution = @vroom.solve(vrp)
    assert solution

    distance_matrix = vrp.matrices.first.distance
    max_ride = problem[:vehicles].first[:maximum_ride_distance]

    solution.routes.each do |route|
      service_stops = route.stops.select(&:service_id)
      previous_index = nil
      service_stops.each do |stop|
        current_index = stop.activity.point.matrix_index
        if previous_index
          assert_operator distance_matrix[previous_index][current_index], :<=, max_ride,
                          'Consecutive services should respect maximum_ride_distance when feasible'
        end
        previous_index = current_index
      end
    end
  end

  def test_maximum_ride_time_with_vroom_solver
    problem = {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 4, 5],
          [4, 0, 3],
          [5, 3, 0]
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
        matrix_id: 'matrix_0',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        cost_time_multiplier: 1,
        maximum_ride_time: 3
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
      }],
      configuration: {
        resolution: {
          duration: 100
        }
      }
    }
    vrp = TestHelper.create(problem)

    refute_includes OptimizerWrapper.config[:services][:vroom].inapplicable_solve?(vrp),
                    :assert_no_ride_constraint

    solution = @vroom.solve(vrp)
    assert solution

    route = solution.routes.first
    service_stops = route.stops.select(&:service_id)
    assert_equal 2, service_stops.size

    previous_index = nil
    matrix = vrp.matrices.first.time

    service_stops.each{ |stop|
      current_index = stop.activity.point.matrix_index
      if previous_index
        assert_operator matrix[previous_index][current_index], :<=, 3,
                        'Consecutive services should respect maximum_ride_time when feasible'
      end
      previous_index = current_index
    }
  end

  def test_duration_modifiers_via_service_and_setup_per_type
    problem = VRP.basic
    problem[:vehicles] << problem[:vehicles].first.dup
    problem[:vehicles].last[:id] = 'vehicle_1'
    problem[:vehicles].first[:coef_service] = 2
    problem[:vehicles].first[:coef_setup] = 2
    problem[:vehicles].first[:additional_service] = 10
    problem[:vehicles].first[:additional_setup] = 5
    problem[:vehicles].last[:coef_service] = 1.5
    problem[:vehicles].last[:coef_setup] = 3
    problem[:services].each{ |service|
      service[:activity][:duration] = 100
      service[:activity][:setup_duration] = 20
    }

    vrp = TestHelper.create(problem)
    refute_includes @vroom.inapplicable_solve?(vrp), :assert_no_service_duration_modifiers
    refute_includes @vroom.inapplicable_solve?(vrp), :assert_no_complex_setup_durations

    vroom_vrp = Wrappers::Vroom.new.send(:vroom_problem, vrp, [:time, :distance])

    types = vroom_vrp[:vehicles].map{ |vehicle| vehicle[:type] }
    assert_equal 2, types.uniq.size
    assert(types.all?)

    job = vroom_vrp[:jobs].first
    assert_equal 100, job[:service]
    assert_equal 20, job[:setup]

    vehicle0 = vrp.vehicles.first
    vehicle1 = vrp.vehicles.last
    type0 = vroom_vrp[:vehicles].first[:type]
    type1 = vroom_vrp[:vehicles].last[:type]
    activity = vrp.services.first.activity

    assert_equal activity.duration_on(vehicle0).round, job[:service_per_type][type0]
    assert_equal activity.duration_on(vehicle1).round, job[:service_per_type][type1]
    assert_equal activity.setup_duration_on(vehicle0).round, job[:setup_per_type][type0]
    assert_equal activity.setup_duration_on(vehicle1).round, job[:setup_per_type][type1]
    assert_equal 210, job[:service_per_type][type0]
    assert_equal 150, job[:service_per_type][type1]
    assert_equal 45, job[:setup_per_type][type0]
    assert_equal 60, job[:setup_per_type][type1]
  end

  def test_no_duration_per_type_without_modifiers
    vrp = TestHelper.create(VRP.basic)
    vroom_vrp = Wrappers::Vroom.new.send(:vroom_problem, vrp, [:time, :distance])

    assert(vroom_vrp[:vehicles].none?{ |vehicle| vehicle.key?(:type) })
    assert(vroom_vrp[:jobs].none?{ |job| job.key?(:service_per_type) || job.key?(:setup_per_type) })
  end
end
