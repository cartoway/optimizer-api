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
require './lib/heuristics/dicho_construction_timings.rb'
require './lib/heuristics/dicho_resolution_timings.rb'
require './lib/heuristics/dicho_level_timings.rb'
require './lib/heuristics/ortools_timings.rb'
require './lib/heuristics/dicho_end_stage_solver.rb'
require './lib/interpreters/compute_several_solutions.rb'
require './lib/tsp_helper.rb'
require './lib/helper.rb'
require './util/job_manager.rb'

module Interpreters
  class Dichotomous
    MIN_DICHO_SOLVE_DURATION_MS = 150

    def self.dicho_time_budget_active?(service_vrp)
      !service_vrp.resolution_time_budget_ms.nil?
    end

    def self.ensure_time_budget!(service_vrp)
      return unless service_vrp.dicho_level.zero?
      return if service_vrp.resolution_time_budget_ms

      duration = service_vrp.vrp.configuration.resolution.duration
      return unless duration

      service_vrp.original_duration_ms = duration
      service_vrp.resolution_time_budget_ms = duration.to_f
      if service_vrp.dicho_data.is_a?(Hash)
        service_vrp.dicho_data[:resolution_duration_ms] = duration.to_f
        service_vrp.dicho_data[:resolution_deadline_monotonic] =
          Process.clock_gettime(Process::CLOCK_MONOTONIC) + duration.to_f / 1000.0
      end
      DichoEndStageSolver.reserve_time_budget!(service_vrp)
    end

    def self.dicho_sub_vrp_weight(vrp)
      vrp.services.size * [1, vrp.vehicles.size].min
    end

    def self.apply_time_budget_to_vrp!(service_vrp)
      budget = service_vrp.resolution_time_budget_ms
      return unless budget

      resolution = service_vrp.vrp.configuration.resolution
      resolution.duration =
        if resolution.duration
          [resolution.duration, budget].min.round
        else
          budget.round
        end
      if resolution.minimum_duration && resolution.minimum_duration > budget
        resolution.minimum_duration = budget.round
      end
    end

    def self.allocate_children_time_budget!(parent, children)
      remaining = parent.resolution_time_budget_ms
      return unless remaining&.positive? && children.any?

      weights = children.map{ |child| dicho_sub_vrp_weight(child.vrp) }
      total_weight = weights.sum
      return unless total_weight.positive?

      children.each_with_index{ |child, index|
        child.resolution_time_budget_ms = (remaining * weights[index] / total_weight).floor
        child.original_duration_ms ||= parent.original_duration_ms
        apply_time_budget_to_vrp!(child)
      }
    end

    def self.remaining_time_budget(service_vrp)
      service_vrp.resolution_time_budget_ms.to_f
    end

    def self.measure_wall_ms
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      wall_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
      [wall_ms, result]
    end

    def self.consume_subtree_time_budget!(service_vrp, subtree_wall_ms, end_stage_wall_before: 0)
      return unless dicho_time_budget_active?(service_vrp)

      dicho_data = service_vrp.dicho_data
      end_stage_delta =
        if dicho_data.is_a?(Hash)
          DichoEndStageSolver.end_stage_wall_consumed_ms(dicho_data) - end_stage_wall_before.to_f
        else
          0
        end
      main_wall_ms = [subtree_wall_ms.to_f - end_stage_delta, 0].max
      consume_time_budget!(service_vrp, main_wall_ms) if main_wall_ms.positive?
    end

    def self.consume_time_budget!(service_vrp, elapsed_ms)
      return unless service_vrp.resolution_time_budget_ms

      service_vrp.resolution_time_budget_ms =
        [service_vrp.resolution_time_budget_ms - elapsed_ms.to_f, 0].max
    end

    def self.apply_solve_duration_cap!(service_vrp)
      return false if DichoEndStageSolver.resolution_deadline_reached?(service_vrp)

      budget = service_vrp.resolution_time_budget_ms
      return true if budget.nil?

      deadline_ms = DichoEndStageSolver.resolution_deadline_remaining_ms(service_vrp)
      budget = [budget, deadline_ms].min if deadline_ms

      return false if budget <= MIN_DICHO_SOLVE_DURATION_MS

      resolution = service_vrp.vrp.configuration.resolution
      resolution.duration = [resolution.duration || budget, budget].min.round
      true
    end

    def self.dichotomous_candidate?(service_vrp)
      config = service_vrp.vrp.configuration
      service_vrp.dicho_level&.positive? ||
        (
          # TODO: remove cost_fixed and duration conditions after exclusion cost calculation is corrected.
          service_vrp.vrp.vehicles.none?{ |vehicle| vehicle.cost_fixed && !vehicle.cost_fixed.zero? } &&
          service_vrp.vrp.vehicles.all?{ |vehicle| vehicle.duration || vehicle.timewindow } &&
          service_vrp.vrp.vehicles.size > config.resolution.dicho_algorithm_vehicle_limit &&
          (config.resolution.vehicle_limit.nil? ||
            config.resolution.vehicle_limit > config.resolution.dicho_algorithm_vehicle_limit) &&
          config.resolution.dicho_algorithm_service_limit.to_i.positive? &&
          service_vrp.vrp.services.size - service_vrp.vrp.routes.map{ |r| r.mission_ids.size }.sum >
            config.resolution.dicho_algorithm_service_limit &&
          !service_vrp.vrp.schedule? &&
          service_vrp.vrp.points.all?{ |point| point&.location&.lat && point&.location&.lon } &&
          service_vrp.vrp.relations.empty? &&
          # TODO: max_split transfer_unused_resources can handle empties_or_fills use that logic in dicho
          service_vrp.vrp.services.none?{ |s| s.quantities.any?(&:fill) || s.quantities.any?(&:empty) }
        )
    end

    def self.feasible_vrp(solution, service_vrp)
      solution.nil? || solution.count_unassigned_services != service_vrp.vrp.services.size ||
        solution.unassigned_stops.reject(&:reason).any?
    end

    def self.dichotomous_heuristic(service_vrp, job = nil, &block)
      solution = nil
      if dichotomous_candidate?(service_vrp)
        vrp = service_vrp.vrp
        level = service_vrp.dicho_level
        dicho_data = service_vrp.dicho_data
        log_message = "dicho - level(#{level}) "\
                  "activities: #{vrp.services.size} "\
                  "vehicles (limit): #{vrp.vehicles.size}(#{vrp.configuration.resolution.vehicle_limit})"\
                  "duration [min, max]: [#{vrp.configuration.resolution.minimum_duration&.round},"\
                  "#{vrp.configuration.resolution.duration&.round}]"
        log log_message, level: :info

        DichoConstructionTimings.ensure!(dicho_data)
        DichoResolutionTimings.ensure!(dicho_data)
        DichoLevelTimings.ensure!(dicho_data)
        DichoLevelTimings.record_context!(dicho_data, level, vrp)
        set_config(service_vrp)
        ensure_time_budget!(service_vrp)

        solution =
          DichoLevelTimings.measure(dicho_data, level, :node_total_ms) {
            build_dicho_node_solution(service_vrp, job, dicho_data, level, vrp, &block)
          }

        if level.zero?
          DichoConstructionTimings.log_summary!(service_vrp)
          OrtoolsTimings.log_summary!(service_vrp)
          DichoResolutionTimings.log_summary!(service_vrp)
          DichoLevelTimings.log_summary!(service_vrp)
        end
      else
        service_vrp.vrp.configuration.resolution.init_duration = nil
      end
      solution
    end

    def self.build_dicho_node_solution(service_vrp, job, dicho_data, level, vrp, &block)
      node_solution = nil

      # Must be called to be sure matrices are complete in vrp and be able to switch vehicles between sub_vrp
      if level.zero?
        DichoLevelTimings.measure(dicho_data, level, :matrix_ms) {
          DichoResolutionTimings.measure(dicho_data, :compute_matrix_ms) {
            DichoResolutionTimings.increment!(dicho_data, :compute_matrix_calls)
            service_vrp.vrp.compute_matrix(job)
          }
        }
        DichoLevelTimings.measure(dicho_data, level, :exclusion_ms) {
          DichoConstructionTimings.measure(dicho_data, :exclusion_costs_ms) {
            service_vrp.vrp.calculate_service_exclusion_costs(:time, true)
          }
        }
        update_exclusion_cost(service_vrp)
      # Do not solve if vrp has too many vehicles or services - init_duration is set in set_config()
      elsif service_vrp.vrp.configuration.resolution.init_duration.nil?
        DichoLevelTimings.measure(dicho_data, level, :exclusion_ms) {
          DichoConstructionTimings.measure(dicho_data, :exclusion_costs_ms) {
            service_vrp.vrp.calculate_service_exclusion_costs(:time, false)
          }
        }
        update_exclusion_cost(service_vrp)
        Interpreters::SeveralSolutions.ensure_dicho_first_solution_strategy!(service_vrp, block)
        if apply_solve_duration_cap!(service_vrp)
          node_solution =
            DichoLevelTimings.measure(dicho_data, level, :pre_split_solve_ms) {
              Core::Strategies::Orchestration.solve(service_vrp, job, block)
            }
        end
      else
        update_exclusion_cost(service_vrp)
      end

      if (node_solution.nil? || node_solution.unassigned_stops.size >= 0.7 * service_vrp.vrp.services.size) &&
         feasible_vrp(node_solution, service_vrp) &&
         service_vrp.vrp.vehicles.size > service_vrp.vrp.configuration.resolution.dicho_division_vehicle_limit &&
         service_vrp.vrp.services.size > service_vrp.vrp.configuration.resolution.dicho_division_service_limit
        node_solution = merge_split_dicho_children(service_vrp, job, dicho_data, level, vrp, &block)
      end

      node_solution
    end

    def self.merge_split_dicho_children(service_vrp, job, dicho_data, level, vrp, &block)
      sub_service_vrps =
        DichoLevelTimings.measure(dicho_data, level, :split_ms) {
          split_results = []
          3.times do |retry_index|
            DichoConstructionTimings.increment!(dicho_data, :split_retries) if retry_index.positive?
            split_results = split(service_vrp, job)
            break if split_results.size == 2 && split_results.none?{ |s_vrp| s_vrp.vrp.services.empty? }
          end
          split_results
        }

      if sub_service_vrps.size != 2 || sub_service_vrps.any?{ |s_vrp| s_vrp.vrp.services.empty? }
        sub_service_vrps.each{ |s_vrp| s_vrp.dicho_data[:cannot_split_further] = true }
        log 'dichotomous_heuristic cannot split the problem into two clusters', level: :warn
      end

      allocate_children_time_budget!(service_vrp, sub_service_vrps) if dicho_time_budget_active?(service_vrp)

      solutions = []
      DichoLevelTimings.measure(dicho_data, level, :children_ms) {
        sub_service_vrps.each_with_index{ |sub_service_vrp, index|
          if DichoEndStageSolver.resolution_deadline_reached?(service_vrp)
            log 'dicho - resolution deadline reached, skipping remaining child', level: :warn
            break
          end

          if index.positive? && dicho_time_budget_active?(service_vrp)
            child_budget = sub_service_vrp.resolution_time_budget_ms
            parent_remaining = remaining_time_budget(service_vrp)
            if child_budget && parent_remaining.positive?
              sub_service_vrp.resolution_time_budget_ms = [child_budget, parent_remaining].min
              apply_time_budget_to_vrp!(sub_service_vrp)
            end
          end

          if service_vrp.selected_first_solution_strategy && sub_service_vrp.selected_first_solution_strategy.nil?
            sub_service_vrp.selected_first_solution_strategy = service_vrp.selected_first_solution_strategy
            Interpreters::SeveralSolutions.apply_propagated_first_solution_strategy!(
              sub_service_vrp.vrp, service_vrp.selected_first_solution_strategy
            )
          end

          end_stage_wall_before = DichoEndStageSolver.end_stage_wall_consumed_ms(dicho_data)
          subtree_wall_ms, child_solution =
            measure_wall_ms {
              Core::Strategies::Orchestration.define_process(
                sub_service_vrp,
                job
              ) { |wrapper, avancement, total, message, cost, time, sol|
                avc = service_vrp.dicho_denominators.map.with_index{ |lvl, idx|
                  Rational(service_vrp.dicho_sides[idx], lvl)
                }.sum

                msg =
                  if message.include?('dichotomous process')
                    message
                  else
                    add = "dichotomous process #{(service_vrp.dicho_denominators.last * avc).to_i}"\
                          "/#{service_vrp.dicho_denominators.last}"
                    Core::Strategies::Orchestration.concat_avancement(add, message)
                  end
                block&.call(wrapper, avancement, total, msg, cost, time, sol)
              }
            }

          if child_solution
            consume_subtree_time_budget!(
              service_vrp,
              subtree_wall_ms,
              end_stage_wall_before: end_stage_wall_before
            )
          end

          if sub_service_vrp.selected_first_solution_strategy && !service_vrp.selected_first_solution_strategy
            service_vrp.selected_first_solution_strategy = sub_service_vrp.selected_first_solution_strategy
          end

          transfer_unused_vehicles(child_solution, sub_service_vrps) if index.zero? && child_solution

          solutions << child_solution
        }
      }
      node_solution = solutions.reduce(&:+)
      log "dicho - level(#{level}) before remove_bad_skills unassigned rate " \
          "#{node_solution.unassigned_stops.size}/#{service_vrp.vrp.services.size}: " \
          "#{(node_solution.unassigned_stops.size.to_f / service_vrp.vrp.services.size * 100).round(1)}%"

      node_solution =
        DichoLevelTimings.measure(dicho_data, level, :postprocess_ms) {
          DichoResolutionTimings.measure(dicho_data, :dicho_postprocess_ms) {
            DichoResolutionTimings.increment!(dicho_data, :dicho_postprocess_calls)
            remove_bad_skills(service_vrp, node_solution)
            Interpreters::SplitClustering.remove_empty_routes(node_solution)
            node_solution.parse(vrp)
            log "dicho - level(#{level}) before end_stage_insert  unassigned rate " \
                "#{node_solution.unassigned_stops.size}/#{service_vrp.vrp.services.size}: " \
                "#{(node_solution.unassigned_stops.size.to_f / service_vrp.vrp.services.size * 100).round(1)}%"

            merged =
              if DichoEndStageSolver.end_stage_active?(service_vrp, node_solution)
                DichoLevelTimings.measure(dicho_data, level, :end_stage_ms) {
                  DichoResolutionTimings.measure(dicho_data, :end_stage_insert_ms) {
                    DichoResolutionTimings.increment!(dicho_data, :end_stage_insert_calls)
                    end_stage_insert_unassigned(service_vrp, node_solution, job)
                  }
                }
              else
                node_solution
              end
            Interpreters::SplitClustering.remove_empty_routes(merged)

            if level.zero?
              log "dicho - before remove_poorly_populated_routes: #{merged.routes.size}"
              Interpreters::SplitClustering.remove_poorly_populated_routes(service_vrp.vrp, merged, 0.5)
              log "dicho - after remove_poorly_populated_routes: #{merged.routes.size}"
            end
            merged.parse(vrp)
          }
        }

      log "dicho - level(#{level}) unassigned rate " \
          "#{node_solution.unassigned_stops.size}/#{service_vrp.vrp.services.size}: " \
          "#{(node_solution.unassigned_stops.size.to_f / service_vrp.vrp.services.size * 100).round(1)}%"
      node_solution
    end

    def self.transfer_unused_vehicles(solution, sub_service_vrps)
      return if sub_service_vrps.size != 2

      sv_zero = sub_service_vrps[0].vrp
      sv_one = sub_service_vrps[1].vrp

      # Transfer the vehicles which do not appear in the routes or the empty vehicles that appear in the routes
      sv_zero.vehicles.each{ |vehicle|
        route = solution.routes.find{ |r| r.vehicle.id == vehicle.id }

        next if route&.stops&.any?(&:service_id)

        sv_one.vehicles << vehicle
        sv_zero.vehicles -= [vehicle]
        vehicle_points = [vehicle.start_point, vehicle.end_point].compact.uniq
        vehicle_points.each{ |new_point|
          existing_point = sv_one.points.find{ |p| p.id == new_point.id }

          if existing_point
            vehicle.start_point = existing_point if vehicle.start_point_id == new_point.id
            vehicle.end_point = existing_point if vehicle.end_point_id == new_point.id
          else
            sv_one.points << new_point
          end
        }

        vehicle.reload_depots.each do |reload_depot|
          reload_point = reload_depot.point
          if reload_point
            existing_reload_point = sv_one.points.find{ |p| p.id == reload_point.id }
            if existing_reload_point
              reload_depot.point = existing_reload_point if reload_depot.point_id == reload_point.id
            else
              sv_one.points << reload_point
            end
          end

          sv_one.reload_depots << reload_depot if sv_one.reload_depots.none?{ |rd| rd.id == reload_depot.id }
          still_used = sv_zero.vehicles.any?{ |veh| veh.reload_depots.include?(reload_depot) }
          sv_zero.reload_depots -= [reload_depot] unless still_used
        end
      }

      # Transfer unsued vehicle limit to the other side as well
      sv_zero_unused_vehicle_limit = sv_zero.configuration.resolution.vehicle_limit - solution.count_used_routes
      sv_one.configuration.resolution.vehicle_limit += sv_zero_unused_vehicle_limit
    end

    def self.dicho_level_coeff(service_vrp)
      balance = 0.66666
      divisor = (service_vrp.vrp.configuration.resolution.vehicle_limit || service_vrp.vrp.vehicles.size).to_f
      level_approx = Math.log(service_vrp.vrp.configuration.resolution.dicho_division_vehicle_limit / divisor,
                              balance)
      power = 1 / (level_approx - service_vrp.dicho_level).to_f
      service_vrp.vrp.configuration.resolution.dicho_level_coeff = 2**power
    end

    def self.set_config(service_vrp) # rubocop: disable Naming/AccessorMethodName, Style/CommentedKeyword
      # service_vrp.vrp.configuration.resolution.batch_heuristic = true
      config = service_vrp.vrp.configuration
      config.restitution.allow_empty_result = true

      if service_vrp.dicho_level&.zero?
        dicho_level_coeff(service_vrp)
        service_vrp.vrp.vehicles.each{ |vehicle|
          vehicle[:cost_fixed] = vehicle[:cost_fixed]&.positive? ? vehicle[:cost_fixed] : 1e6
          vehicle[:cost_distance_multiplier] = 0.05 if vehicle[:cost_distance_multiplier].zero?
        }
      end

      config.resolution.init_duration = 90000 if config.resolution.duration > 90000
      config.resolution.vehicle_limit ||= service_vrp.vrp[:vehicles].size
      config.resolution.init_duration =
        if (service_vrp.dicho_sides.nil? || !service_vrp.dicho_data[:cannot_split_further]) &&
           service_vrp.vrp.vehicles.size > config.resolution.dicho_division_vehicle_limit &&
           service_vrp.vrp.services.size > config.resolution.dicho_division_service_limit &&
           config.resolution.vehicle_limit > config.resolution.dicho_division_vehicle_limit
          1000
        end

      service_vrp
    end

    def self.update_exclusion_cost(service_vrp)
      return if service_vrp.dicho_level.zero?

      average_exclusion_cost = service_vrp.vrp.services.sum(&:exclusion_cost) / service_vrp.vrp.services.size
      service_vrp.vrp.services.each{ |service|
        multiplier = (service_vrp.vrp.configuration.resolution.dicho_level_coeff**service_vrp.dicho_level - 1)
        service.exclusion_cost += average_exclusion_cost * multiplier
      }
    end

    def self.build_initial_routes(solutions)
      solutions.flat_map{ |solution|
        next if solution.nil?

        solution.routes.map{ |route|
          missions = route.stops.map{ |stop|
            next if stop.is_a?(Models::Solution::StopDepot) || stop.mission.is_a?(Models::Rest)

            stop.mission
          }.compact
          next if missions.empty?

          Models::Route.create(
            vehicle: route.vehicle,
            missions: missions
          )
        }
      }.compact
    end

    def self.remove_bad_skills(service_vrp, solution)
      log '---> remove_bad_skills', level: :debug
      solution.routes.each{ |r|
        r.stops.each{ |a|
          next unless a.service_id

          service = service_vrp.vrp.services.find{ |s| s.id == a.service_id }
          next unless service && !service.skills.empty?

          next unless r.vehicle.skills.all?{ |xor_skills| (service.skills & xor_skills).size != service.skills.size }

          log "dicho - removed service #{a.service_id} from vehicle #{r.vehicle.id}"
          solution.unassigned_stops << a
          r.stops.delete(a)
          # TODO: remove bad sticky?
        }
      }
      log '<--- remove_bad_skills', level: :debug
    end

    def self.insert_unassigned_by_skills(service_vrp, unassigned_services, unassigned_with_skills,
                                         skills, solution)
      vrp = service_vrp.vrp
      log "try to insert #{unassigned_with_skills.size} unassigned from #{vrp.services.size} services"
      vrp.routes = build_initial_routes([solution])
      vrp.configuration.resolution.init_duration = nil

      vehicles_with_skills = vrp.vehicles.map.with_index{ |vehicle, v_index|
        r_index = solution.routes.index{ |route| route.vehicle.id == vehicle.id }
        compatible =
          if skills.any?
            vehicle.skills.any?{ |or_skills| (skills & or_skills).size == skills.size }
          else
            true
          end
        [vehicle.id, r_index, v_index] if compatible
      }.compact

      # Shuffle so that existing routes will be distributed randomly
      # Otherwise we might have a sub_vrp with 6 existing routes (no empty routes) and
      # hundreds of services which makes it very hard to insert a point
      # With shuffle we distribute the existing routes accross all sub-vrps we create
      vehicles_with_skills.shuffle!

      # TODO: Here we launch the optim of a single skill however, it make sense to include the vehicles
      # without skills (especially the ones with existing routes) in the sub_vrp because that way optim
      # can move points between vehicles and serve an unserviced point with skills.

      # TODO: We do not consider the geographic closeness/distance of routes and points.
      # This might be the reason why sometimes we have solutions with long detours.
      # However, it is not very easy to find a generic and effective way.

      sub_solutions = []
      vehicle_count = (skills.empty? && !vrp.routes.empty?) ? [vrp.routes.size, 6].min : 3
      solve_count = 0
      sorted_unassigned_with_skills =
        unassigned_with_skills.sort_by{ |service| -service.exclusion_cost.to_f }
      impacted_routes = []
      end_stage_budget_active = DichoEndStageSolver.dedicated_time_budget?(service_vrp)
      vehicles_with_skills.each_slice(vehicle_count) do |vehicles_indices|
        break if DichoEndStageSolver.resolution_deadline_reached?(service_vrp)
        if end_stage_budget_active &&
           DichoEndStageSolver.remaining_end_stage_time_budget(service_vrp) <= MIN_DICHO_SOLVE_DURATION_MS
          break
        end

        remaining_service_ids =
          (
            solution.unassigned_stops.map(&:service_id) & sorted_unassigned_with_skills.map(&:id)
          ).sort_by{ |service_id|
            service = sorted_unassigned_with_skills.find{ |s| s.id == service_id }
            - service&.exclusion_cost.to_f
          }
        next if remaining_service_ids.empty?

        before_remaining_unassigned = remaining_service_ids.size

        rate_vehicles = vehicles_indices.size / vehicles_with_skills.size.to_f
        rate_services = unassigned_services.empty? ? 1 : unassigned_with_skills.size / unassigned_services.size.to_f

        used_vehicle_count = vehicles_indices.count{ |_v_id, r_index, _v_index| r_index }

        solve_duration_ms =
          [
            MIN_DICHO_SOLVE_DURATION_MS,
            vrp.configuration.resolution.duration.to_f / 3.99 * rate_vehicles * rate_services
          ].max.to_i

        if end_stage_budget_active
          solve_duration_ms = DichoEndStageSolver.cap_end_stage_solve_duration!(service_vrp, solve_duration_ms)
          break unless solve_duration_ms
        end

        if vrp.configuration.resolution.vehicle_limit
          sub_vrp_vehicle_limit = @leftover_vehicle_limit + used_vehicle_count
          next if sub_vrp_vehicle_limit&.zero? # vehicle limit hit, cannot use more new vehicles
        end

        assigned_service_ids = vehicles_indices.map{ |_v, r_i, _v_i| r_i }.compact.flat_map{ |r_i|
          solution.routes[r_i].stops.map(&:service_id)
        }.compact

        solve_count += 1
        DichoEndStageSolver.record_insert_attempt!(service_vrp.dicho_data)

        slice_wall_ms, slice_result =
          measure_wall_ms {
            sub_service_vrp = SplitClustering.build_partial_service_vrp(service_vrp,
                                                                        remaining_service_ids + assigned_service_ids,
                                                                        vehicles_indices.map{ |_v, _r_i, v_i| v_i })
            sub_vrp = sub_service_vrp.vrp
            sub_vrp.vehicles.each{ |vehicle|
              impacted_routes << vehicle.id
              vehicle.cost_fixed = vehicle.cost_fixed&.positive? ? vehicle.cost_fixed : 1e6
              vehicle.cost_distance_multiplier = 0.05 if vehicle.cost_distance_multiplier.zero?
            }

            resolution = sub_vrp.configuration.resolution
            resolution.vehicle_limit = sub_vrp_vehicle_limit if vrp.configuration.resolution.vehicle_limit

            resolution.minimum_duration =
              if resolution.minimum_duration
                [(vrp.configuration.resolution.minimum_duration.to_f / 3.99 * rate_vehicles * rate_services).to_i,
                 100].max
              end
            resolution.duration = solve_duration_ms

            sub_vrp.configuration.restitution.allow_empty_result = true

            if service_vrp.selected_first_solution_strategy && sub_service_vrp.selected_first_solution_strategy.nil?
              sub_service_vrp.selected_first_solution_strategy = service_vrp.selected_first_solution_strategy
              SeveralSolutions.apply_propagated_first_solution_strategy!(
                sub_service_vrp.vrp, service_vrp.selected_first_solution_strategy
              )
            end

            solution_loop = Core::Strategies::Orchestration.solve(sub_service_vrp)
            [sub_service_vrp, solution_loop]
          }

        sub_service_vrp, solution_loop = slice_result

        if end_stage_budget_active
          DichoEndStageSolver.consume_end_stage_elapsed!(service_vrp, slice_wall_ms)
        end

        unless solution_loop
          DichoEndStageSolver.record_insert_no_result!(service_vrp.dicho_data)
          next
        end

        solution.elapsed += solution_loop.elapsed.to_f

        if remaining_service_ids.size < solution_loop.unassigned_stops.size
          DichoEndStageSolver.record_insert_rejected!(service_vrp.dicho_data)
          next
        end

        after_remaining_unassigned =
          (solution_loop.unassigned_stops.map(&:service_id) & remaining_service_ids).size
        inserted_count = before_remaining_unassigned - after_remaining_unassigned
        DichoEndStageSolver.record_insert_success!(service_vrp.dicho_data)
        DichoEndStageSolver.record_inserted!(service_vrp.dicho_data, inserted_count)

        if vrp.configuration.resolution.vehicle_limit # correct the lefover vehicle limit count
          @leftover_vehicle_limit -=
            solution_loop.count_used_routes - used_vehicle_count
        end

        remove_bad_skills(sub_service_vrp, solution_loop)

        Helper.replace_routes_in_result(solution, solution_loop)
        solution.parse(vrp)
        sub_solutions << solution_loop
      end
      new_routes = build_initial_routes(sub_solutions)
      vrp.routes.delete_if{ |r| impacted_routes.include?(r.vehicle_id) }
      vrp.routes += new_routes
    end

    def self.end_stage_insert_unassigned(service_vrp, solution, _job = nil)
      log "---> dicho::end_stage - level(#{service_vrp.dicho_level})"
      return solution if solution.unassigned_stops.empty?

      vrp = service_vrp.vrp
      dicho_data = service_vrp.dicho_data
      before_unassigned = solution.unassigned_stops.size
      end_stage_before = DichoResolutionTimings.end_stage_counter_snapshot(dicho_data)
      log "try to insert #{before_unassigned} unassigned from #{vrp.services.size} services"
      vrp.routes = build_initial_routes([solution])
      vrp.configuration.resolution.init_duration = nil
      unassigned_service_ids = solution.unassigned_stops.map(&:service_id).compact
      unassigned_services = vrp.services.select{ |s| unassigned_service_ids.include?(s.id) }
      unassigned_services_by_skills =
        unassigned_services.sort_by{ |service| -service.exclusion_cost.to_f }
                           .group_by(&:skills)

      @leftover_vehicle_limit = vrp.configuration.resolution.vehicle_limit - solution.routes.size

      # TODO: sort unassigned_services with no skill / sticky at the end
      unassigned_services_by_skills[[]] = [] if unassigned_services_by_skills.empty?

      unassigned_services_by_skills.each{ |skills, un_w_services|
        next if solution.unassigned_stops.empty?

        insert_unassigned_by_skills(service_vrp, unassigned_services, un_w_services,
                                    skills, solution)
      }
      after_unassigned = solution.unassigned_stops.size
      net_inserted = before_unassigned - after_unassigned
      end_stage_delta = DichoResolutionTimings.end_stage_counter_delta(
        end_stage_before,
        DichoResolutionTimings.end_stage_counter_snapshot(dicho_data)
      )
      log "dicho end_stage level(#{service_vrp.dicho_level}): unassigned #{before_unassigned}->#{after_unassigned} " \
          "(net -#{net_inserted}) attempts=#{end_stage_delta[:end_stage_insert_attempts]} " \
          "successes=#{end_stage_delta[:end_stage_insert_successes]} " \
          "rejected=#{end_stage_delta[:end_stage_insert_rejected]} " \
          "no_result=#{end_stage_delta[:end_stage_insert_no_result]} " \
          "inserted=#{end_stage_delta[:end_stage_services_inserted]}",
          level: :info
      solution
    ensure
      log "<--- dicho::end_stage - level(#{service_vrp.dicho_level})"
    end

    def self.split(service_vrp, job = nil)
      log "---> dicho::split - level(#{service_vrp.dicho_level})"

      unless service_vrp.dicho_data[:service_vehicle_assignments]
        service_vrp.dicho_data, _empties_or_fills = SplitClustering.initialize_split_data(service_vrp, job)
      end
      dicho_data = service_vrp.dicho_data
      DichoConstructionTimings.increment!(dicho_data, :splits_count)
      DichoLevelTimings.increment!(dicho_data, service_vrp.dicho_level, :splits_count)

      enum_current_vehicles = dicho_data[:current_vehicles].select

      representative_sub_vrp = SplitClustering.create_representative_sub_vrp(dicho_data)

      sides =
        DichoConstructionTimings.measure(dicho_data, :split_kmeans_ms) {
          SplitClustering.split_balanced_kmeans(
            Models::ResolutionContext.new({ vrp: representative_sub_vrp }), 2,
            SplitClustering.representative_split_kmeans_options(dicho_data)
          )
        }.sort_by!{ |side|
          [side.size, side.sum(&:visits_number)] # [number_of_vehicles, number_of_visits]
        }.reverse!.collect!{ |side|
          enum_current_vehicles.select{ |v| side.any?{ |s| s.id == "0_representative_vrp_s_#{v.id}" } }
        }

      split_service_vrps = []
      sides.select(&:any?).collect.with_index{ |side, i|
        local_dicho_data = dicho_data.dup
        local_dicho_data[:current_vehicles] = side

        split_service_vrps << Models::ResolutionContext.new(
          service: service_vrp.service,
          vrp: DichoConstructionTimings.measure(dicho_data, :create_sub_vrp_ms) {
            SplitClustering.create_sub_vrp(local_dicho_data)
          },
          dicho_data: local_dicho_data,
          dicho_level: service_vrp.dicho_level + 1,
          # dicho_denominators and dicho_sides logic comes from
          # https://github.com/braktar/optimizer-api/commit/1abb786365b4582c7279540c46e541a80f76a489
          dicho_denominators: service_vrp.dicho_denominators + [2**(service_vrp.dicho_level + 1)],
          dicho_sides: service_vrp.dicho_sides + [i],
          original_duration_ms: service_vrp.original_duration_ms,
          selected_first_solution_strategy:
            service_vrp.selected_first_solution_strategy || service_vrp.dicho_data[:selected_first_solution_strategy],
        )
      }

      log "<--- dicho::split - level(#{service_vrp.dicho_level})"
      split_service_vrps
    end
  end
end
