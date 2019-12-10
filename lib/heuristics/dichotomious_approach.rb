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

require './lib/interpreters/split_clustering.rb'
require './lib/clusterers/balanced_kmeans.rb'
require './lib/tsp_helper.rb'
require './lib/helper.rb'
require 'ai4r'

module Interpreters
  class Dichotomious

    def self.dichotomious_candidate(service_vrp)
      service_vrp[:vrp].vehicles.size > 3 &&
      service_vrp[:vrp].services.size - service_vrp[:vrp].routes.map{ |r| r[:mission_ids].size }.sum > 50 &&
      service_vrp[:vrp].shipments.empty? &&
      # (service_vrp[:vrp].vehicles.all?(&:force_start) || service_vrp[:vrp].vehicles.all?{ |vehicle| vehicle[:shift_preference] == 'force_start' }) &&
      service_vrp[:vrp].vehicles.all?{ |vehicle| vehicle.cost_late_multiplier.nil? || vehicle.cost_late_multiplier == 0 } &&
      service_vrp[:vrp].services.all?{ |service| service.activity.late_multiplier.nil? || service.activity.late_multiplier == 0 } &&
      service_vrp[:vrp].services.any?{ |service| service.activity.timewindows && !service.activity.timewindows.empty? }
    end

    def self.dichotomious_heuristic(service_vrp, job)
      if dichotomious_candidate(service_vrp)
        set_config(service_vrp)
        t1 = Time.now
        # Must be called to be sure matrices are complete in vrp and be able to switch vehicles between sub_vrp
        # TODO: only compute matrix should be called
        result = OptimizerWrapper.solve([service_vrp], job)
        t2 = Time.now

        if result.nil? || result[:unassigned].size >= 0.7 * service_vrp[:vrp].services.size
          sub_service_vrps = []
          loop do
            sub_service_vrps = split(service_vrp)
            break if sub_service_vrps.size == 2
          end
          results = sub_service_vrps.map.with_index{ |sub_service_vrp, index|
            result = OptimizerWrapper.define_process([sub_service_vrp], job)
            if index.zero?
              result[:routes].each{ |r|
                if r[:activities].select{ |a| a[:service_id] }.empty?
                  vehicle = sub_service_vrps[0][:vrp].vehicles.find{ |v| v.id == r[:vehicle_id] }
                  sub_service_vrps[1][:vrp].vehicles << vehicle
                  sub_service_vrps[1][:vrp].points += sub_service_vrps[0][:vrp].points.select{ |p| p.id == vehicle.start_point_id || p.id == vehicle.end_point_id }
                  sub_service_vrps[1][:vrp].resolution_vehicle_limit += 1
                end
              }
            end
            result
          }
          result = Helper.merge_results(results)
          result[:elapsed] += (t2 - t1) * 1000

          remove_bad_skills(service_vrp, result)

          result = end_stage_insert_unassigned(service_vrp, result, job)

          if service_vrp[:level].zero?
            # Remove vehicles which are half empty
            Interpreters::SplitClustering.remove_poorly_populated_routes(service_vrp[:vrp], result, 0.5)
          end
        end
      else
        service_vrp[:vrp].resolution_init_duration = nil
      end
      result
    end

    def self.set_config(service_vrp)
      service_vrp[:vrp].calculate_service_exclusion_costs(:time, true)

      # service_vrp[:vrp].resolution_batch_heuristic = true
      service_vrp[:vrp].restitution_allow_empty_result = true
      service_vrp[:vrp].resolution_duration = service_vrp[:vrp].resolution_duration ? (service_vrp[:vrp].resolution_duration / 2.25).to_i : 120000 # TODO: Time calculation is inccorect due to end_stage. We need a better time limit calculation
      service_vrp[:vrp].resolution_minimum_duration = service_vrp[:vrp].resolution_minimum_duration ? (service_vrp[:vrp].resolution_minimum_duration / 2.25).to_i : 90000
      service_vrp[:vrp].resolution_init_duration = 90000 if service_vrp[:vrp].resolution_duration > 90000
      service_vrp[:vrp].resolution_vehicle_limit ||= service_vrp[:vrp][:vehicles].size
      service_vrp[:vrp].resolution_init_duration = 10 if service_vrp[:vrp].vehicles.size > 4 && service_vrp[:vrp].resolution_vehicle_limit > 4 || service_vrp[:vrp].services.size > 200
      service_vrp[:vrp].preprocessing_first_solution_strategy = ['parallel_cheapest_insertion'] # A bit slower than local_cheapest_insertion; however, returns better results on ortools-v7.

      service_vrp
    end

    def self.build_initial_routes(results)
      results.flat_map{ |result|
        next if result.nil?
        result[:routes].map{ |route|
          next if route.nil?
          mission_ids = route[:activities].map{ |activity| activity[:service_id] || activity[:rest_id] }.compact
          next if mission_ids.empty?
          Models::Route.new(
            vehicle: {
              id: route[:vehicle_id]
            },
            mission_ids: mission_ids
          )
        }
      }.compact
    end

    def self.remove_bad_skills(service_vrp, result)
      Interpreters::SplitClustering.remove_empty_routes(result)
      result[:routes].each{ |r|
        r[:activities].each{ |a|
          if a[:service_id]
            service = service_vrp[:vrp].services.find{ |s| s.id == a[:service_id] }
            vehicle = service_vrp[:vrp].vehicles.find{ |v| v.id == r[:vehicle_id] }
            if service && !service.skills.empty?
              if vehicle.skills.all?{ |xor_skills| (service.skills & xor_skills).size != service.skills.size }
                result[:unassigned] << a
                r[:activities].delete(a)
              end
            end
            # TODO: remove bad sticky?
          end
        }
      }
      Interpreters::SplitClustering.remove_empty_routes(result)
    end

    def self.end_stage_insert_unassigned(service_vrp, result, job = nil)
      if !result[:unassigned].empty? && dichotomious_candidate(service_vrp)
        service_vrp[:vrp].routes = build_initial_routes([result])
        service_vrp[:vrp].resolution_init_duration = nil
        unassigned_services = service_vrp[:vrp].services.select{ |s| result[:unassigned].map{ |a| a[:service_id] }.include?(s.id) }
        unassigned_services_by_skills = unassigned_services.group_by{ |s| s.skills }
        # TODO: sort unassigned_services with no skill / sticky at the end
        unassigned_services_by_skills.each{ |skills, services|
          next if result[:unassigned].empty?
          vehicles_with_skills = skills.empty? ? service_vrp[:vrp].vehicles : service_vrp[:vrp].vehicles.select{ |v|
            v.skills.any?{ |or_skills| (skills & or_skills).size == skills.size }
          }
          sticky_vehicle_ids = unassigned_services.flat_map(&:sticky_vehicles).compact.map(&:id)
          # In case services has incoherent sticky and skills, sticky is the winner
          unless sticky_vehicle_ids.empty?
            vehicles_with_skills = service_vrp[:vrp].vehicles.select{ |v| sticky_vehicle_ids.include?(v.id) }
          end
          # Priorize existing vehicles already assigned
          vehicles_with_skills.sort_by{ |v| service_vrp[:vrp].routes.map{ |r| r.vehicle.id }.include?(v.id) ? 0 : 1 }

          sub_results = []
          vehicle_count = skills.empty? && !service_vrp[:vrp].routes.empty? ? [service_vrp[:vrp].routes.size, 6].min : 3
          vehicles_with_skills.each_slice(vehicle_count) do |vehicles|
            remaining_service_ids = result[:unassigned].map{ |u| u[:service_id] } & services.map(&:id)
            next if remaining_service_ids.empty?
            assigned_service_ids = result[:routes].select{ |r| vehicles.map(&:id).include?(r[:vehicle_id]) }.flat_map{ |r| r[:activities].map{ |a| a[:service_id] } }.compact

            sub_service_vrp = SplitClustering.build_partial_service_vrp(service_vrp, remaining_service_ids + assigned_service_ids, vehicles.map(&:id))
            sub_service_vrp[:vrp].vehicles.each{ |vehicle|
              vehicle[:cost_fixed] = vehicle[:cost_fixed] && vehicle[:cost_fixed] > 0 ? vehicle[:cost_fixed] : 1e6
            }
            rate_vehicles = sub_service_vrp[:vrp].vehicles.size / service_vrp[:vrp].vehicles.size.to_f
            rate_services = services.size / unassigned_services.size.to_f
            sub_service_vrp[:vrp].resolution_duration = (service_vrp[:vrp].resolution_duration / (2.0 * (service_vrp[:level] + 1)) * rate_vehicles * rate_services).to_i
            sub_service_vrp[:vrp].resolution_minimum_duration = (service_vrp[:vrp].resolution_minimum_duration / (1.0 * (service_vrp[:level] + 1)) * rate_vehicles * rate_services).to_i
            # sub_service_vrp[:vrp].resolution_vehicle_limit = sub_service_vrp[:vrp].vehicles.size
            sub_service_vrp[:vrp].restitution_allow_empty_result = true

            result_loop = OptimizerWrapper.solve([sub_service_vrp], job)
            result[:elapsed] += result_loop[:elapsed] if result_loop

            # Initial routes can be refused... check unassigned size before take into account solution
            if result_loop && remaining_service_ids.size >= result_loop[:unassigned].size
              remove_bad_skills(sub_service_vrp, result_loop)
              result[:unassigned].delete_if{ |unassigned_activity|
                result_loop[:routes].any?{ |route|
                  route[:activities].any?{ |activity| activity[:service_id] == unassigned_activity[:service_id] }
                }
              }
              # result[:unassigned] |= result_loop[:unassigned] # Cannot use | operator because :type field not always present...
              result[:unassigned].delete_if{ |activity| result_loop[:unassigned].map{ |a| a[:service_id] }.include?(activity[:service_id]) }
              result[:unassigned] += result_loop[:unassigned]
              result[:routes].delete_if{ |old_route|
                result_loop[:routes].map{ |r| r[:vehicle_id] }.include?(old_route[:vehicle_id])
              }
              result[:routes] += result_loop[:routes]
              # TODO: merge costs, total_infos...
              sub_results << result_loop
            end
          end
          new_routes = build_initial_routes(sub_results)
          vehicle_ids = sub_results.flat_map{ |r| r[:routes].map{ |route| route[:vehicle_id] } }
          service_vrp[:vrp].routes.delete_if{ |r| vehicle_ids.include?(r.vehicle.id) }
          service_vrp[:vrp].routes += new_routes
        }
      end
      result
    end

    def self.split_vehicles(vrp, services_by_cluster)
      services_skills_by_clusters = services_by_cluster.map{ |services|
        services.map{ |s| s.skills.empty? ? nil : s.skills.uniq.sort }.compact.uniq
      }
      vehicles_by_clusters = [[], []]
      vrp.vehicles.each{ |v|
        cluster_index = nil
        # Vehicle skills is an array of array of strings
        unless v.skills.empty?
          # If vehicle has skills which match with service skills in only one cluster, prefer this cluster for this vehicle
          preferered_index = []
          services_skills_by_clusters.each_with_index{ |services_skills, index|
            preferered_index << index if services_skills.any?{ |skills| v.skills.any?{ |v_skills| (skills & v_skills).size == skills.size } }
          }
          cluster_index = preferered_index.first if preferered_index.size == 1
        end
        # TODO: prefer cluster with sticky vehicle
        # TODO: avoid to prefer always same cluster
        cluster_index ||= vehicles_by_clusters[0].size <= vehicles_by_clusters[1].size ? 0 : 1
        vehicles_by_clusters[cluster_index] << v
      }
      vehicles_by_clusters
    end

    def self.split(service_vrp)
      vrp = service_vrp[:vrp]
      vrp.resolution_vehicle_limit ||= vrp.vehicles.size
      services_by_cluster = kmeans(vrp, :duration).sort_by{ |ss| Helper.services_duration(ss) }.reverse
      split_service_vrps = []
      if services_by_cluster.size == 2
        # Kmeans return 2 vrps
        vehicles_by_cluster = split_vehicles(vrp, services_by_cluster)
        if vehicles_by_cluster[1].size > vehicles_by_cluster[0].size
          services_by_cluster.reverse
          vehicles_by_cluster.reverse
        end
        [0, 1].each{ |i|
          sub_vrp = SplitClustering.build_partial_service_vrp(service_vrp, services_by_cluster[i].map(&:id))[:vrp]
          sub_vrp.vehicles = vehicles_by_cluster[i]
          sub_vrp.vehicles.each{ |vehicle|
            vehicle[:cost_fixed] = vehicle[:cost_fixed] && vehicle[:cost_fixed] > 0 ? vehicle[:cost_fixed] : 1e6
          }
          # TODO: à cause de la grande disparité du split_vehicles par skills, on peut rapidement tomber à 1...
          sub_vrp.resolution_vehicle_limit = [sub_vrp.vehicles.size, vrp.vehicles.empty? ? 0 : (sub_vrp.vehicles.size / vrp.vehicles.size.to_f * vrp.resolution_vehicle_limit).ceil].min
          sub_vrp.points = sub_vrp.services.map{ |service| service.activity.point }.uniq
          sub_vrp.points += sub_vrp.shipments.flat_map{ |shipment| [shipment.pickup.point, shipment.delivery.point] }.uniq
          sub_vrp.points += sub_vrp.vehicles.flat_map{ |vehicle| [vehicle.start_point, vehicle.end_point] }.compact.uniq
          sub_vrp.preprocessing_first_solution_strategy = ['self_selection'] # ???

          split_service_vrps << {
            service: service_vrp[:service],
            vrp: sub_vrp,
            level: service_vrp[:level] + 1
          }
        }
      else
        raise 'Incorrect split size with kmeans' if services_by_cluster.size > 2
        # Kmeans return 1 vrp
        sub_vrp = SplitClustering::build_partial_service_vrp(service_vrp, services_by_cluster[0].map(&:id))[:vrp]
        sub_vrp.points = vrp.points
        sub_vrp.vehicles = vrp.vehicles
        sub_vrp.vehicles.each{ |vehicle|
          vehicle[:cost_fixed] = vehicle[:cost_fixed] && vehicle[:cost_fixed] > 0 ? vehicle[:cost_fixed] : 1e6
        }
        split_service_vrps << {
          service: service_vrp[:service],
          vrp: sub_vrp,
          level: service_vrp[:level]
        }
      end
      SplitClustering.output_clusters(split_service_vrps) if service_vrp[:vrp][:debug_output_clusters]

      split_service_vrps
    end

    # TODO: remove this method and use SplitClustering class instead
    def self.kmeans(vrp, cut_symbol)
      nb_clusters = 2
      # Split using balanced kmeans
      if vrp.services.all?{ |service| service[:activity] }
        unit_symbols = vrp.units.collect{ |unit| unit.id.to_sym } << :duration << :visits
        cumulated_metrics = Hash.new(0)
        data_items = []

        # Collect data for kmeans
        vrp.points.each{ |point|
          unit_quantities = Hash.new(0)
          related_services = vrp.services.select{ |service| service[:activity][:point_id] == point[:id] }
          related_services.each{ |service|
            unit_quantities[:visits] += 1
            cumulated_metrics[:visits] += 1
            unit_quantities[:duration] += service[:activity][:duration]
            cumulated_metrics[:duration] += service[:activity][:duration]
            service.quantities.each{ |quantity|
              unit_quantities[quantity.unit_id.to_sym] += quantity.value
              cumulated_metrics[quantity.unit_id.to_sym] += quantity.value
            }
          }

          next if related_services.empty?
          related_services.each{ |related_service|
            if related_service[:sticky_vehicle_ids] && related_service[:skills] && !related_service[:skills].empty?
              data_items << [point.location.lat, point.location.lon, point.id, unit_quantities, related_service[:sticky_vehicle_ids], related_service[:skills], 0]
            elsif related_service[:sticky_vehicle_ids] && related_service[:skills] && related_service[:skills].empty?
                data_items << [point.location.lat, point.location.lon, point.id, unit_quantities, related_service[:sticky_vehicle_ids], [], 0]
            elsif related_service[:skills] && !related_service[:skills].empty? && !related_service[:sticky_vehicle_ids]
              data_items << [point.location.lat, point.location.lon, point.id, unit_quantities, [], related_service[:skills], 0]
            else
              data_items << [point.location.lat, point.location.lon, point.id, unit_quantities, [], [], 0]
            end
          }
        }

        clusters, _centroid_indices = SplitClustering.kmeans_process([], 100, 5, nb_clusters, data_items, unit_symbols, cut_symbol, cumulated_metrics[cut_symbol] / nb_clusters, vrp, rate_balance: 0)

        services_by_cluster = clusters.collect{ |cluster|
          cluster.data_items.collect{ |data|
            vrp.services.find{ |service| service.activity.point_id == data[2] }
          }
        }
        services_by_cluster
      else
        puts 'Split not available when services have no activities'
        [vrp]
      end
    end
  end
end
