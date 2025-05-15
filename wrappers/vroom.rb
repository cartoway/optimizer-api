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
require './wrappers/wrapper'

module Wrappers
  class Vroom < Wrapper
    CUSTOM_QUANTITY_BIGNUM = 1e3

    def initialize(hash = {})
      super(hash)
      @exec_vroom = hash[:exec_vroom] || '../vroom/bin/vroom'
      @exec_vroom += " -t #{hash[:threads]}" if hash[:threads]
    end

    def prioritize_first_available_trips_and_vehicles(*)
      # no-op
      # TODO: remove this override when vroom can handle different fixed costs
    end

    def solver_constraints
      super + [
        # Costs
        :assert_vehicles_objective,

        # Problem
        :assert_correctness_matrices_vehicles_and_points_definition,
        :assert_no_evaluation,
        :assert_no_partitions,
        :assert_no_relations_except_simple_shipments,
        :assert_no_subtours,
        :assert_points_same_definition,

        # Vehicle/route constraints
        :assert_no_ride_constraint,
        :assert_no_service_duration_modifiers,
        :assert_vehicles_no_capacity_initial,
        :assert_vehicles_no_duration_limit,
        :assert_vehicles_no_force_start,
        :assert_vehicles_no_late_multiplier,
        :assert_vehicles_no_overload_multiplier,
        :assert_vehicles_start_or_end,
        :assert_no_overall_duration,

        # Mission constraints
        :assert_no_activity_with_position,
        :assert_no_empty_or_fill,
        :assert_no_exclusion_cost,
        :assert_no_complex_setup_durations,
        :assert_services_no_late_multiplier,
        :assert_only_one_visit,

        # Solver
        :assert_no_first_solution_strategy,
        :assert_no_free_approach_or_return,
        :assert_no_planning_heuristic,
        :assert_small_minimum_duration,
        :assert_solver,
      ]
    end

    def solve_synchronous?(vrp)
      compatible_routers = %i[car truck_medium]
      vrp.points.size < 200 &&
        !Interpreters::SplitClustering.split_solve_candidate?({ vrp: vrp }) &&
        vrp.vehicles.all?{ |vehicle|
          compatible_routers.include?(vehicle.router_mode&.to_sym)
        } # WARNING: this should change accordingly with router evolution
    end

    def solve(vrp, job = nil, _thread_proc = nil)
      if vrp.vehicles.empty? || vrp.points.empty? || vrp.services.empty?
        return vrp.empty_solution(:vroom)
      end

      rest_equivalence(vrp)

      tic = Time.now
      problem = vroom_problem(vrp, [:time, :distance])
      result = run_vroom(problem, job, 2, vrp.configuration.resolution.duration)
      elapsed_time = (Time.now - tic) * 1000

      return if !result

      cost = (result['summary']['cost'])
      routes =
        result['routes'].map{ |route|
          @previous = nil
          vehicle = vrp.vehicles[route['vehicle']]
          cost += vehicle.cost_fixed if route['steps'].any?
          stops = route['steps'].map{ |step|
            read_step(vrp, vehicle, step)
          }.compact
          initial_loads =
            route['steps'].first['load']&.map&.with_index{ |load, l_index|
              Models::Solution::Load.new(quantity: Models::Quantity.new(unit: vrp.units[l_index]), current: load)
            }
          Models::Solution::Route.new(
            initial_loads: initial_loads,
            stops: stops,
            vehicle: vehicle,
            info: Models::Solution::Route::Info.new(
              start_time: stops.first.info.begin_time,
              end_time: stops.last.info.begin_time + stops.last.activity.duration
            )
          )
        }

      unassigneds = result['unassigned'].map{ |step| read_unassigned(vrp, step) }

      log 'Solution cost: ' + cost.to_s + ' & unassigned: ' + unassigneds.size.to_s, level: :info

      solution =
        Models::Solution.new(
          elapsed: elapsed_time,
          solvers: [:vroom],
          routes: routes,
          unassigned_stops: unassigneds
        )
      solution.parse(vrp)
    end

    private

    def rest_equivalence(vrp)
      rest_index = 0
      @rest_hash = {}
      vrp.vehicles.each{ |vehicle|
        vehicle.rests.each{ |rest|
          @rest_hash["#{vehicle.id}_#{rest.id}"] = {
            index: rest_index,
            vehicle: vehicle.id,
            rest: rest
          }
          rest_index += 1
        }
      }
      @rest_hash
    end

    def read_step(vrp, vehicle, step)
      case step['type']
      when 'job', 'pickup', 'delivery'
        read_activity(vrp, vehicle, step)
      when 'start', 'end'
        read_depot(vrp, vehicle, step)
      when 'break'
        read_break(step)
      else
        raise 'Unimplemented stop type in wrappers/vroom.rb'
      end
    end

    def read_unassigned(vrp, step)
      read_activity(vrp, nil, step)
    end

    def read_break(step)
      original_rest = @rest_hash.find{ |_key, value| value[:index] == step['id'] }.last[:rest]
      begin_time = step['arrival'] + step['waiting_time']

      times = {
        begin_time: begin_time,
        end_time: begin_time && (begin_time + step['service']),
        departure_time: begin_time && (begin_time + step['service'])
      }
      Models::Solution::Stop.new(original_rest, info: Models::Solution::Stop::Info.new(times))
    end

    def read_depot(vrp, vehicle, step)
      point = step['type'] == 'start' ? vehicle&.start_point : vehicle&.end_point
      return nil if point.nil?

      route_data = step['type'] == 'end' ? compute_route_data(vrp, vehicle, point, step) : {}
      @previous = point

      times = {
        begin_time: step['arrival']
      }.merge(route_data)
      if step['type'] == 'end'
        Models::Solution::StopDepot.new(vehicle.end_point, info: Models::Solution::Stop::Info.new(times))
      else
        Models::Solution::StopDepot.new(vehicle.start_point, info: Models::Solution::Stop::Info.new(times))
      end
    end

    def read_activity(vrp, vehicle, act_step)
      service = @object_id_map[act_step['id']]
      point = service.activity.point
      route_data = compute_route_data(vrp, vehicle, point, act_step)
      begin_time = act_step['arrival'] && (act_step['arrival'] + act_step['waiting_time'] + act_step['setup'])
      times = {
        begin_time: begin_time,
        end_time: begin_time && (begin_time + act_step['service']),
        departure_time: begin_time && (begin_time + act_step['service'])
      }.merge(route_data)
      loads =
        vrp.units.map.with_index{ |unit, u_index|
          Models::Solution::Load.new(
            quantity: Models::Quantity.new(unit: unit),
            current: act_step['load'] && (act_step['load'][u_index].to_f / CUSTOM_QUANTITY_BIGNUM) || 0
          )
        }
      job_data = Models::Solution::Stop.new(service, info: Models::Solution::Stop::Info.new(times), loads: loads)
      @previous = point
      job_data
    end

    def compute_route_data(vrp, vehicle, point, step)
      return {} if step['type'].nil?

      return { travel_time: 0, travel_distance: 0, travel_value: 0 } unless @previous && point.matrix_index

      matrix = vrp.matrices.find{ |m| m.id == vehicle.matrix_id } if vehicle

      {
        travel_time: (matrix && matrix[:time]) ? matrix[:time][@previous.matrix_index][point.matrix_index] : 0,
        travel_distance: (matrix && matrix[:distance]) ? matrix[:distance][@previous.matrix_index][point.matrix_index] : 0,
        travel_value: (matrix && matrix[:value]) ? matrix[:value][@previous.matrix_index][point.matrix_index] : 0
      }
    end

    def collect_skills(object, vrp_skills)
      return [] unless vrp_skills.any?

      [vrp_skills.size] +
        if object.is_a?(Models::Vehicle)
          [vrp_skills.find_index{ |sk| sk == object.id }].compact +
          (object.skills&.first&.map{ |skill| vrp_skills.find_index{ |sk| sk == skill } } || []).compact
        else
          object.skills.flat_map{ |skill| vrp_skills.find_index{ |sk| sk == skill } }.compact
        end
    end

    def collect_jobs(vrp, vrp_skills, vrp_units)
      @object_id_map ||= {}
      # ignore the services with a shipment relation
      vrp.services.select{ |s| s.relations.none?{ |r| r.type == :shipment } }.map{ |service|
        # Activity is mandatory
        index = @object_id_map.size
        @object_id_map[index] = service
        {
          id: index,
          location_index: service.activity.point.matrix_index,
          service: service.activity.duration,
          setup: service.activity.setup_duration,
          skills: collect_skills(service, vrp_skills),
          priority: (100 * (8 - service.priority).to_f / 8).to_i, # Scale from 0 to 100 (higher is more important)
          time_windows: service.activity.timewindows.map{ |timewindow|
            [timewindow.start - service.activity.setup_duration,
             (timewindow.end || 2**30) - service.activity.setup_duration]
          },
          delivery: vrp_units.map{ |unit|
            q = service.quantities.find{ |quantity| quantity.unit.id == unit.id && quantity.value.negative? }
            @total_quantities[unit.id] -= q&.value || 0
            (-(q&.value || 0) * CUSTOM_QUANTITY_BIGNUM).round
          },
          pickup: vrp_units.map{ |unit|
            q = service.quantities.find{ |quantity| quantity.unit.id == unit.id && quantity.value.positive? }
            @total_quantities[unit.id] += q&.value || 0
            ((q&.value || 0) * CUSTOM_QUANTITY_BIGNUM).round
          }
        }.delete_if{ |_k, v|
          v.nil? || v.is_a?(Array) && v.empty?
        }
      }
    end

    def collect_shipments(vrp, vrp_skills, vrp_units)
      vrp.relations.select{ |r| r.type == :shipment }.map{ |relation|
        pickup_service, delivery_service = relation.linked_services
        collect_shipments_core(pickup_service, delivery_service, vrp_skills, vrp_units)
      }
    end

    def collect_shipments_core(pickup_service, delivery_service, vrp_skills, vrp_units)
      @object_id_map ||= {}
      # handles both services in shipment relation and model:shipments
      # activity_objects [array] contains the two services (pickup and delivery) or the shipment
      # activities [array] contains the model:activity of the
      # services (pickup.activity, delivery.activity) or the shipment (shipment.pickup, shipment.delivery)
      # types [array] contains the type of the objects -- i.e., [:service, :service]
      # for services in shipment relation or [:pickup, :delivery] for model:shipment
      pickup_index = @object_id_map.size
      delivery_index = pickup_index + 1

      @object_id_map[pickup_index] = pickup_service
      @object_id_map[delivery_index] = delivery_service
      {
        amount: vrp_units.map{ |unit|
          value = pickup_service.quantities.find{ |quantity| quantity.unit.id == unit.id }&.value.to_f.abs
          @total_quantities[unit.id] += value
          (value * CUSTOM_QUANTITY_BIGNUM).round
        },
        skills: collect_skills(pickup_service, vrp_skills) | collect_skills(delivery_service, vrp_skills),
        priority: (100 * (8 - pickup_service.priority).to_f / 8).to_i,
        pickup: {
          id: pickup_index,
          service: pickup_service.activity.duration,
          setup: pickup_service.activity.setup_duration,
          location_index: pickup_service.activity.point.matrix_index,
          time_windows: pickup_service.activity.timewindows.map{ |tw|
            [tw.start - pickup_service.activity.setup_duration,
             (tw.end || 2**30) - pickup_service.activity.setup_duration]
          }
        }.delete_if{ |_k, v| v.nil? || v.is_a?(Array) && v.empty? },
        delivery: {
          id: delivery_index,
          service: delivery_service.activity.duration,
          setup: delivery_service.activity.setup_duration,
          location_index: delivery_service.activity.point.matrix_index,
          time_windows: delivery_service.activity.timewindows.map{ |tw|
            [tw.start - delivery_service.activity.setup_duration,
             (tw.end || 2**30) - delivery_service.activity.setup_duration]
          }
        }.delete_if{ |_k, v| v.nil? || v.is_a?(Array) && v.empty? }
      }.delete_if{ |_k, v|
        v.nil? || v.is_a?(Array) && v.empty?
      }
    end

    def collect_vehicles(vrp, vrp_skills, vrp_units)
      vrp.vehicles.map.with_index{ |vehicle, index|
        {
          id: index,
          profile: "m#{vehicle.matrix_id}",
          start_index: vehicle.start_point&.matrix_index,
          end_index: vehicle.end_point&.matrix_index,
          capacity: vrp_units.map{ |unit|
            c = vehicle.capacities.find{ |capacity| capacity.unit.id == unit.id }
            ((c&.limit || @total_quantities[unit.id]) * CUSTOM_QUANTITY_BIGNUM).round
          },
          time_window: [vehicle.timewindow&.start || 0, vehicle.timewindow&.end || 2**30],
          # VROOM expects a default skill
          skills: collect_skills(vehicle, vrp_skills),
          breaks: vehicle.rests.map{ |rest|
            rest_index = @rest_hash["#{vehicle.id}_#{rest.id}"][:index]
            {
              id: rest_index,
              service: rest.duration,
              time_windows: rest.timewindows.map{ |tw| [tw&.start || 0, tw&.end || 2**30] }
            }
          },
          costs: {
            fixed: vehicle.cost_fixed.to_i,
            per_km: vehicle.cost_distance_multiplier && (vehicle.cost_distance_multiplier * 1000).to_i,
            per_hour: vehicle.cost_time_multiplier && (vehicle.cost_time_multiplier * 3600).to_i
          }.delete_if{ |k, v| v.nil? || v.zero? },
          max_distance: vehicle.distance
        }.delete_if{ |k, v|
          v.nil? || v.is_a?(Array) && v.empty? ||
            k == :time_window && v.first.zero? && v.last == 2**30
        }
      }
    end

    def vroom_problem(vrp, dimensions)
      problem = { vehicles: [], jobs: [], matrices: [] }
      @total_quantities = Hash.new { 0 }
      # WARNING: only first alternative set of skills is used
      vrp_skills = vrp.vehicles.flat_map{ |vehicle| vehicle.skills.first }.uniq
      vrp_units =
        vrp.units.select{ |unit|
          vrp.vehicles.map{ |vehicle|
            vehicle.capacities.find{ |capacity|
              capacity.unit.id == unit.id
            }&.limit
          }&.compact&.max&.positive?
        }
      problem[:jobs] = collect_jobs(vrp, vrp_skills, vrp_units)
      problem[:vehicles] = collect_vehicles(vrp, vrp_skills, vrp_units)
      problem[:shipments] = collect_shipments(vrp, vrp_skills, vrp_units)
      problem[:matrices] = {}

      # Reduce the unreachable value in the matrices to avoid VROOM overflow
      max_end = problem[:vehicles].map{ |vehicle| vehicle[:time_window]&.last || 2**20 }.max + 1
      vrp.matrices.each{ |m|
        problem[:matrices]["m#{m.id}"] = {
          durations: m.integer_time(max_end),
          distances: m.integer_distance(max_end)
        }.delete_if{ |_k, v| v.nil? || v.is_a?(Array) && v.empty? }
      }
      problem.delete_if{ |_k, v| v.nil? || v.is_a?(Array) && v.empty? }
      problem
    end

    def run_vroom(problem, _job, level = 0, timeout = nil)
      input = Tempfile.new('optimize-vroom-input', @tmp_dir)

      input.write(problem.to_json)
      input.close

      output = Tempfile.new('optimize-vroom-output', @tmp_dir)
      output.close

      # TODO : find best value for x https://github.com/Mapotempo/optimizer-api/pull/203
      cmd = "#{@exec_vroom} -i '#{input.path}' -o '#{output.path}' -x #{level} #{timeout ? "-l #{timeout / 1000}" : ''}"
      log cmd
      _stdout, stderr, status = Open3.capture3(cmd)

      raise OptimizerWrapper::UnsupportedProblemError.new("VROOM - #{stderr[8..]}") if !status.success?

      JSON.parse(File.read(output.path)) if status.exitstatus.zero?
    ensure
      input&.unlink
      output&.unlink
    end
  end
end
