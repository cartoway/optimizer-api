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

module Models
  class VehicleTest < IsolatedTest
    def test_work_duration
      vrp = VRP.periodic_seq_timewindows
      vrp = TestHelper.create(vrp)

      # work duration is only supposed to be called when there is no schedule
      # therefore, work_duration should not be called if vehicle has sequence_timewindows
      assert_raises do
        vrp.vehicles.first.work_duration
      end

      vrp.vehicles.first.sequence_timewindows = []
      assert_equal 2**32, vrp.vehicles.first.work_duration

      vrp.vehicles.first.timewindow = { start: 10 }
      assert_equal 2**32, vrp.vehicles.first.work_duration

      vrp.vehicles.first.timewindow = { end: 10 }
      assert_equal 10, vrp.vehicles.first.work_duration

      vrp.vehicles.first.timewindow = { start: 10, end: 20 }
      assert_equal 10, vrp.vehicles.first.work_duration

      vrp.vehicles.first.duration = 5
      assert_equal 5, vrp.vehicles.first.work_duration
    end

    def test_total_work_time_in_range
      vrp = VRP.lat_lon_periodic
      vrp = TestHelper.create(vrp)
      assert_equal 32400 * 4, vrp.vehicles.first.total_work_time_in_range(0, 3)

      vrp.vehicles.first.reset_computed_data
      vrp.vehicles.first.duration = 5
      assert_equal 5 * 4, vrp.vehicles.first.total_work_time_in_range(0, 3)

      vrp.vehicles.first.reset_computed_data
      vrp.vehicles.first.timewindow = nil
      assert_equal 20, vrp.vehicles.first.total_work_time_in_range(0, 3) # because duration is still 5

      vrp.vehicles.first.reset_computed_data
      vrp.vehicles.first.duration = nil
      assert_equal 2**32, vrp.vehicles.first.total_work_time_in_range(0, 3)

      vrp.vehicles.first.reset_computed_data
      vrp.vehicles.first.sequence_timewindows = [Models::Timewindow.create({ start: 1, end: 4 })]
      assert_equal 12, vrp.vehicles.first.total_work_time_in_range(0, 3)

      vrp.vehicles.first.reset_computed_data
      vrp.vehicles.first.sequence_timewindows << Models::Timewindow.create({ start: 5, end: 6, day_index: 0 })
      assert_equal 13, vrp.vehicles.first.total_work_time_in_range(0, 3)
    end

    def test_skills
      vehicle1 = { id: 'vehicle_1' }
      vehicle2 = { id: 'vehicle_2' }

      v1 = Models::Vehicle.create(vehicle1)
      v2 = Models::Vehicle.create(vehicle2)

      refute_equal v1.skills.object_id, v2.skills.object_id
      refute_equal v1.skills.first.object_id, v2.skills.first.object_id

      problem = { vehicles: [vehicle1, vehicle2] }

      vrp = Models::Vrp.create(problem)

      refute_equal vrp.vehicles.first.skills.object_id,
                   vrp.vehicles.last.skills.object_id

      refute_equal vrp.vehicles.first.skills.first.object_id,
                   vrp.vehicles.last.skills.first.object_id

      Models.delete_all
      vehicle1[:skills] = nil
      vehicle2[:skills] = nil

      v1 = Models::Vehicle.create(vehicle1)
      v2 = Models::Vehicle.create(vehicle2)

      refute_equal v1.skills.object_id, v2.skills.object_id
      refute_equal v1.skills.first.object_id, v2.skills.first.object_id

      problem = { vehicles: [vehicle1, vehicle2] }

      vrp = Models::Vrp.create(problem)

      refute_equal vrp.vehicles.first.skills.object_id,
                   vrp.vehicles.last.skills.object_id

      refute_equal vrp.vehicles.first.skills.first.object_id,
                   vrp.vehicles.last.skills.first.object_id
    end

    def test_symbol_skills
      vehicle1 = { id: 'vehicle_1', skills: [['string']] }

      v1 = Models::Vehicle.create(vehicle1)

      assert v1.skills.first.first.is_a?(Symbol)
      assert v1.as_json[:skills].first.first.is_a?(Symbol)
    end

    def test_router_options_matches_router_api_matrix_params
      vehicle = Models::Vehicle.create(
        id: 'vehicle_0',
        low_emission_zone: false,
        large_light_vehicle: false
      )

      router_api_options = %i[
        traffic departure speed_multiplier area speed_multiplier_area
        track motorway toll low_emission_zone large_light_vehicle
        trailers weight weight_per_axle height width length
        hazardous_goods max_walk_distance approach snap strict_restriction
      ]

      assert_equal router_api_options.sort, vehicle.router_options.keys.sort
      refute vehicle.router_options[:low_emission_zone]
      refute vehicle.router_options[:large_light_vehicle]
      assert_nil vehicle.router_options[:approach]
    end
  end
end
