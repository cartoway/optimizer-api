# Copyright © Mapotempo, 2019
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
require 'date'

class MultiTripsTest < Minitest::Test
  def test_expand_vehicles_trips
    vrp = VRP.lat_lon
    vrp[:vehicles].first[:trips] = 2

    vrp = Interpreters::MultiTrips.new.expand(TestHelper.create(vrp))

    assert_equal 2, vrp.vehicles.size
    assert_equal 1, vrp.relations.size
    vrp.relations.each{ |relation|
      assert_equal :vehicle_trips, relation.type
      assert_includes relation.linked_vehicle_ids, 'vehicle_0_trip_0'
      assert_includes relation.linked_vehicle_ids, 'vehicle_0_trip_1'
    }
  end

  def test_consecutive_expand
    vrp = VRP.lat_lon_two_vehicles
    vrp[:vehicles].first[:trips] = 2

    vrp = TestHelper.create(vrp)
    Interpreters::MultiTrips.new.expand(vrp)
    assert_equal 3, vrp.vehicles.size
    Interpreters::MultiTrips.new.expand(vrp) # consecutive MultiTrips.expand should not produce any error
    assert_equal 3, vrp.vehicles.size
  end

  def test_solve_vehicles_trips
    # this test will be cleaned and moved with multi_tour developments
    size = 5
    problem = {
      units: [{
        id: 'parcels'
      }],
      matrices: [{
        id: 'matrix_0',
        time: [
          [0,  1,  1, 10,  0],
          [1,  0,  1, 10,  1],
          [1,  1,  0, 10,  1],
          [10, 10, 10, 0, 10],
          [0,  1,  1, 10,  0]
        ],
        distance: [
          [0,  1,  1, 10,  0],
          [1,  0,  1, 10,  1],
          [1,  1,  0, 10,  1],
          [10, 10, 10, 0, 10],
          [0,  1,  1, 10,  0]
        ]
      }],
      points: (0..(size - 1)).collect{ |i|
        {
          id: "point_#{i}",
          matrix_index: i
        }
      },
      vehicles: [{
        id: 'vehicle_0',
        start_point_id: 'point_0',
        matrix_id: 'matrix_0',
        timewindow: {
          start: 1,
          end: 30
        },
        trips: 2,
        capacities: [{
          unit_id: 'parcels',
          limit: 2
        }]
      }],
      services: (1..(size - 1)).collect{ |i|
        {
          id: "service_#{i}",
          activity: {
            point_id: "point_#{i}"
          },
          quantities: [{
            unit_id: 'parcels',
            value: 1
          }]
        }
      },
      configuration: {
        resolution: {
          duration: 20,
        }
      }
    }
    result = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:ortools] }}, TestHelper.create(problem), nil)
    assert_equal 2, result[:routes].size
    route0 = result[:routes].find{ |route| route[:vehicle_id] == 'vehicle_0_trip_0' }
    route1 = result[:routes].find{ |route| route[:vehicle_id] == 'vehicle_0_trip_1' }
    assert route0
    assert route1
    assert route0[:activities].last[:departure_time] <= route1[:activities].first[:begin_time]
  end

  def test_vehicle_trips_with_lapse_0
    problem = VRP.lat_lon_two_vehicles
    problem[:relations] = [{
      type: :vehicle_trips,
      lapse: 0,
      linked_vehicle_ids: problem[:vehicles].collect{ |v| v[:id] }
    }]

    result = OptimizerWrapper.wrapper_vrp('demo', { services: { vrp: [:ortools] }}, TestHelper.create(problem), nil)
    first_route = result[:routes].find{ |r| r[:vehicle_id] == 'vehicle_0' }
    second_route = result[:routes].find{ |r| r[:vehicle_id] == 'vehicle_1' }
    assert_operator first_route[:end_time], :<=, second_route[:start_time]
  end
end
