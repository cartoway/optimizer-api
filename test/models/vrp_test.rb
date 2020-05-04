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
  class VrpTest < Minitest::Test
    include Rack::Test::Methods

    def test_deduced_range_indices
      vrp = VRP.scheduling
      vrp[:configuration][:schedule] = {
        range_date: {
          start: Date.new(2020, 1, 1), # wednesday
          end: Date.new(2020, 1, 6) # saturday
        }
      }

      new_vrp = TestHelper.create(vrp)
      assert_equal({ start: 2, end: 7 }, new_vrp.schedule_range_indices)

      vrp[:configuration][:schedule] = {
        range_date: {
          start: Date.new(2019, 12, 30), # wednesday
          end: Date.new(2020, 1, 6) # saturday
        }
      }
      new_vrp = TestHelper.create(vrp)
      assert_equal({ start: 0, end: 7 }, new_vrp.schedule_range_indices)
    end

    def test_visits_computation
      vrp = VRP.scheduling_seq_timewindows
      vrp = TestHelper.create(vrp)

      assert_equal vrp.services.size, vrp.visits

      vrp = VRP.scheduling_seq_timewindows
      vrp = TestHelper.create(vrp)
      vrp.services.each{ |service| service[:visits_number] *= 2 }

      assert_equal 2 * vrp.services.size, vrp.visits

      vrp = TestHelper.load_vrp(self, fixture_file: 'instance_clustered')
      assert_equal vrp.services.collect{ |s| s[:visits_number] }.sum, vrp.visits
    end

    def test_vrp_scheduling
      vrp = VRP.toy
      vrp = TestHelper.create(vrp)
      refute vrp.schedule_range_indices

      vrp = VRP.scheduling_seq_timewindows
      vrp = TestHelper.create(vrp)
      assert vrp.schedule_range_indices
    end

    def test_month_indice_generation
      problem = VRP.basic
      problem[:relations] = [{
        type: 'vehicle_group_duration_on_months',
        linked_vehicle_ids: ['vehicle_0'],
        lapse: 2,
        periodicity: 1
      }]
      problem[:configuration][:preprocessing]
      problem[:configuration][:schedule] = {
        range_date: { start: Date.new(2020, 1, 31), end: Date.new(2020, 2, 1) }
      }

      vrp = TestHelper.create(problem)
      assert_equal [[4], [5]], vrp.schedule_months_indices
    end

    def test_unavailable_visit_day_date_transformed_into_indice
      vrp = VRP.basic
      vrp[:configuration][:schedule] = { range_date: { start: Date.new(2020, 1, 1), end: Date.new(2020, 1, 2) }}
      vrp[:services][0][:unavailable_visit_day_date] = [Date.new(2020, 1, 1)]
      vrp[:services][1][:unavailable_visit_day_date] = [Date.new(2020, 1, 2)]
      created_vrp = TestHelper.create(vrp)
      assert_equal [2], created_vrp.services[0].unavailable_visit_day_indices
      assert_equal [3], created_vrp.services[1].unavailable_visit_day_indices
    end

    def test_reject_work_day_partition
      vrp = VRP.scheduling
      vrp[:services].each{ |s|
        s[:visits_number] = 1
        s[:minimum_lapse] = 2
        s[:maximum_lapse] = 3
      }
      vrp[:configuration][:preprocessing][:partitions] = [{ entity: :work_day }]
      TestHelper.create(vrp) # no raise

      vrp = VRP.scheduling
      vrp[:services].each{ |s|
        s[:visits_number] = 2
        s[:minimum_lapse] = 2
      }
      vrp[:configuration][:preprocessing][:partitions] = [{ entity: :work_day }]
      TestHelper.create(vrp) # no raise

      vrp = VRP.scheduling
      vrp[:services].each{ |s|
        s[:visits_number] = 2
        s[:minimum_lapse] = 2
        s[:maximum_lapse] = 3
      }
      vrp[:configuration][:preprocessing][:partitions] = [{ entity: :work_day }]
      assert_raises OptimizerWrapper::DiscordantProblemError do
        TestHelper.create(vrp)
      end

      vrp = VRP.scheduling
      vrp[:services].each{ |s|
        s[:visits_number] = 2
        s[:minimum_lapse] = 2
        s[:maximum_lapse] = 7
      }
      vrp[:configuration][:preprocessing][:partitions] = [{ entity: :work_day }]
      TestHelper.create(vrp) # no raise
    end
  end
end
