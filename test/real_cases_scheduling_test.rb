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

class HeuristicTest < Minitest::Test
  def compare_data(vrp, result, unit, delta)
    expected_value = vrp.services.map{ |service| find_service_quantity(service, unit) * service[:visits_number] }.compact.sum.round(3)
    actual_result_value = result[:routes].flat_map{ |route| route[:activities].map{ |stop| find_detail_quantity(stop, unit) } }.compact.sum.round(3)
    actual_unassigned_value = result[:unassigned].collect{ |stop| find_detail_quantity(stop, unit) }.compact.sum.round(3)
    assert_in_delta expected_value, actual_result_value + actual_unassigned_value, delta
  end

  def find_service_quantity(service, unit)
    service[:quantities].find{ |qte| qte[:unit][:id] == unit }[:value]
  end

  def find_detail_quantity(activity, unit)
    if activity[:service_id]
      quantity = activity[:detail][:quantities].find{ |qte| qte[:unit] == unit }
      quantity && quantity[:value]
   end
  end

  if !ENV['SKIP_REAL_SCHEDULING']

    def test_instance_baleares2
      vrp = FCT.load_vrp(self)
      result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
      assert result
      assert result[:unassigned].size <= 3
      assert_equal vrp[:services].size, result[:routes].collect{ |route| route[:activities].select{ |stop| stop[:service_id] }.size }.sum + result[:unassigned].size
      assert_equal result[:routes].collect{ |route| route[:activities].select{ |activity| activity[:service_id] }.collect{ |activity| activity[:detail][:quantities][0][:value] }.sum }.sum  + result[:unassigned].collect{ |unassigned| unassigned[:detail][:quantities][0][:value] }.sum, vrp.services.collect{ |service| service[:quantities][0][:value] }.sum, vrp.services.collect{ |service| service[:quantities][0][:value] }.sum
      assert result[:routes].none?{ |route| route[:activities].reject{ |stop| stop[:detail][:quantities].empty? }.collect{ |stop| stop[:detail][:quantities][0][:value] }.sum > vrp.vehicles.find{ |vehicle| vehicle[:id] == route[:vehicle_id] }[:capacities][0][:limit] }
      assert_equal result[:routes].collect{ |route| route[:activities].collect{ |activity| activity[:service_id] } }.flatten.compact.size, result[:routes].collect{ |route| route[:activities].collect{ |activity| activity[:service_id] } }.flatten.compact.uniq.size
    end

    def test_instance_baleares2_with_priority
      vrp = FCT.load_vrp(self)
      result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
      assert result
      assert result[:unassigned].none?{ |service| service[:service_id].include?('3359') }
      assert result[:unassigned].none?{ |service| service[:service_id].include?('0110') }
      assert_equal vrp[:services].size, result[:routes].collect{ |route| route[:activities].select{ |stop| stop[:service_id] }.size }.sum + result[:unassigned].size
      assert_equal result[:routes].collect{ |route| route[:activities].select{ |activity| activity[:service_id] }.collect{ |activity| activity[:detail][:quantities][0][:value] }.sum }.sum  + result[:unassigned].collect{ |unassigned| unassigned[:detail][:quantities][0][:value] }.sum, vrp.services.collect{ |service| service[:quantities][0][:value] }.sum, vrp.services.collect{ |service| service[:quantities][0][:value] }.sum
      assert result[:routes].none?{ |route| route[:activities].reject{ |stop| stop[:detail][:quantities].empty? }.collect{ |stop| stop[:detail][:quantities][0][:value] }.sum > vrp.vehicles.find{ |vehicle| vehicle[:id] == route[:vehicle_id] }[:capacities][0][:limit] }
      assert_equal result[:routes].collect{ |route| route[:activities].collect{ |activity| activity[:service_id] } }.flatten.compact.size, result[:routes].collect{ |route| route[:activities].collect{ |activity| activity[:service_id] } }.flatten.compact.uniq.size
    end

    def test_instance_andalucia2
      vrp = FCT.load_vrp(self)
      result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
      assert result
      assert_equal 11, result[:unassigned].size
      assert_equal vrp[:services].size, result[:routes].collect{ |route| route[:activities].select{ |stop| stop[:service_id] }.size }.sum + result[:unassigned].size
      assert_equal result[:routes].collect{ |route| route[:activities].select{ |activity| activity[:service_id] }.collect{ |activity| activity[:detail][:quantities][0][:value] }.sum }.sum + result[:unassigned].collect{ |unassigned| unassigned[:detail][:quantities][0][:value] }.sum, vrp.services.collect{ |service| service[:quantities][0][:value] }.sum
      assert result[:routes].none?{ |route| route[:activities].reject{ |stop| stop[:detail][:quantities].empty? }.collect{ |stop| stop[:detail][:quantities][0][:value] }.sum > vrp.vehicles.find{ |vehicle| vehicle[:id] == route[:vehicle_id] }[:capacities][0][:limit] }
      assert_equal (result[:routes].collect{ |route| route[:activities].collect{ |activity| activity[:service_id] } } + result[:unassigned].collect{ |unassigned| unassigned[:service_id] }).flatten.compact.size, (result[:routes].collect{ |route| route[:activities].collect{ |activity| activity[:service_id] } } + result[:unassigned].collect{ |unassigned| unassigned[:service_id] }).flatten.compact.uniq.size
    end

    def test_instance_andalucia1_two_vehicles
      vrp = FCT.load_vrp(self)
      result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
      assert result
      assert_equal 0, result[:unassigned].size
      assert_equal vrp[:services].size, result[:routes].collect{ |route| route[:activities].select{ |stop| stop[:service_id] }.size }.sum
      assert_equal result[:routes].collect{ |route| route[:activities].select{ |activity| activity[:service_id] }.collect{ |activity| activity[:detail][:quantities][0] ? activity[:detail][:quantities][0][:value] : 0 }.sum }.sum + result[:unassigned].collect{ |unassigned| unassigned[:detail][:quantities][0] ? unassigned[:detail][:quantities][0][:value] : 0 }.sum, vrp.services.collect{ |service| service[:quantities][0] ? service[:quantities][0][:value] : 0 }.sum
      assert result[:routes].none?{ |route| route[:activities].reject{ |stop| stop[:detail][:quantities].empty? }.collect{ |stop| stop[:detail][:quantities][0][:value] }.sum > vrp.vehicles.find{ |vehicle| vehicle[:id] == route[:vehicle_id] }[:capacities][0][:limit] }
      assert_equal result[:routes].collect{ |route| route[:activities].collect{ |activity| activity[:service_id] } }.flatten.compact.size, result[:routes].collect{ |route| route[:activities].collect{ |activity| activity[:service_id] } }.flatten.compact.uniq.size
    end

    def test_instance_800unaffected_clustered
      skip 'Currently call VROOM which does not return quantities'
      vrp = FCT.load_vrp(self)
      result = OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] }}, vrp, nil)
      assert result
      assert_equal vrp[:services].collect{ |service| service[:visits_number] }.sum.to_i, result[:routes].collect{ |route| route[:activities].select{ |stop| stop[:service_id] }.size }.sum + result[:unassigned].size

      %w[kg qte l].each{ |unit|
        compare_data(vrp, result, unit, 0)

        assert(result[:routes].none?{ |route|
          route[:activities].reject{ |stop| stop[:detail][:quantities].empty? }.collect{ |stop|
            stop[:detail][:quantities].find{ |qte| qte[:unit][:id] == unit }[:value]
          }.sum > vrp[:vehicles].find{ |vehicle|
            vehicle[:id] == route[:vehicle_id].split('_')[0]
          }[:capacities].find{ |cap| cap[:unit_id] == unit }[:limit]
        })
      }
      assert_equal result[:routes].collect{ |route| route[:activities].collect{ |activity| activity[:service_id] } }.flatten.compact.size, result[:routes].collect{ |route| route[:activities].collect{ |activity| activity[:service_id] } }.flatten.compact.uniq.size
    end

    def test_instance_800unaffected_clustered_same_point
      skip 'Currently call VROOM which does not return quantities'
      vrp = FCT.load_vrp(self)
      result = OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] }}, vrp, nil)
      assert result
      assert_equal vrp[:services].collect{ |service| service[:visits_number] }.sum.to_i, result[:routes].collect{ |route| route[:activities].select{ |stop| stop[:service_id] }.size }.sum + result[:unassigned].size

      %w[kg qte l].each{ |unit|
        compare_data(vrp, result, unit, 0)

        result[:routes].each{ |route|
          vehicle_capacity = vrp[:vehicles].find{ |vehicle| vehicle[:id] == route[:vehicle_id].split('_')[0] }[:capacities].find{ |cap| cap[:unit_id] == unit }[:limit]

          vehicle_load = route[:activities].reject{ |stop|
            stop[:detail][:quantities].empty?
          }.collect{ |stop|
            stop[:detail][:quantities].find{ |quan|
              quan[:unit][:id] == unit
            }[:value]
          }.sum

          assert vehicle_load <= vehicle_capacity
        }
      }

      allocated_service_ids = result[:routes].collect{ |route| route[:activities].collect{ |activity| activity[:service_id] } }.flatten.compact

      assert_equal allocated_service_ids.size, allocated_service_ids.uniq.size
    end

    def test_vrp_allow_partial_assigment_false
      vrp = FCT.load_vrp(self)
      result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)

      unassigned = result[:unassigned].collect{ |un| un[:service_id] }
      original_ids = unassigned.collect{ |id| id.split('_').slice(0, 4).join('_') }
      assert(unassigned.all?{ |id|
        nb_visits = id.split('_').last.to_i
        original_id = id.split('_').slice(0, 4).join('_')
        original_ids.count(original_id) == nb_visits
      })

      result[:routes].each{ |route|
        route[:activities].each_with_index{ |activity, index|
          next if index == 0 || index > route[:activities].size - 3
          assert route[:activities][index + 1][:begin_time] == route[:activities][index + 1][:detail][:timewindows].first[:start] + route[:activities][index + 1][:detail][:setup_duration] ? true :
            (assert_equal route[:activities][index + 1][:begin_time], activity[:departure_time] + route[:activities][index + 1][:travel_time] + route[:activities][index + 1][:detail][:setup_duration])
        }
      }
    end

    def test_two_phases_clustering_sched_with_freq_and_same_point_day_5veh
      # about 3 minutes
      vrp = FCT.load_vrp(self)
      total_visits = vrp[:services].collect{ |s| s[:visits_number] }.sum
      result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
      assert result

      assert_equal total_visits, result[:routes].collect{ |route| route[:activities].select{ |stop| stop[:service_id] }.size }.sum + result[:unassigned].size,
        "Found #{result[:routes].collect{ |route| route[:activities].select{ |stop| stop[:service_id] }.size }.sum + result[:unassigned].size} instead of #{total_visits} expected"

      vrp[:services].group_by{ |s| s[:activity][:point][:id] }.each{ |point_id, services_set|
        expected_number_of_days = services_set.collect{ |service| service[:visits_number] }.max
        days_used = result[:routes].collect{ |r| r[:activities].select{ |stop| stop[:point_id] == point_id }.size }.select(&:positive?).size
        assert days_used <= expected_number_of_days, "Used #{days_used} for point #{point_id} instead of #{expected_number_of_days} expected."
      }

      assert result[:unassigned].size < total_visits * 5 / 100, "#{result[:unassigned].size * 100 / total_visits}% unassigned instead of 5% authorized"
      assert result[:unassigned].none?{ |un| un[:reason].include?(' vehicle ') }, 'Some services could not be assigned to a vehicle'
    end

    def test_scheduling_and_ortools
      vrp = FCT.load_vrp(self)
      # clustering before to have no randomness in results
      clusters = Interpreters::SplitClustering.split_balanced_kmeans({ vrp: vrp, service: :demo }, 5, cut_symbol: :duration, entity: 'vehicle', restarts: 1)
      clusters.each{ |cluster|
        cluster[:vrp].preprocessing_partitions = nil
        result = OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] } }, Marshal.load(Marshal.dump(cluster[:vrp])), nil) # marshal dump needed, otherwise we create relations (min/maximum lapse)
        unassigned = result[:unassigned].size

        cluster[:vrp].resolution_solver = true
        result = OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] } }, cluster[:vrp], nil)
        assert unassigned >= result[:unassigned].size, "Increased number of unassigned with ORtools : had #{unassigned}, has #{result[:unassigned].size} now"
      }
    end
  end
end
