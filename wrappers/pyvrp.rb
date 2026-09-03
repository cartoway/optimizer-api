require './wrappers/wrapper'

module Wrappers
  class PyVRP < Wrapper
    CUSTOM_QUANTITY_BIGNUM = 1e3
    MAX_INT64 = 2**63 - 1

    def solver_constraints
      super + [
        # Costs
        :assert_vehicles_objective,

        # Problem
        :assert_correctness_matrices_vehicles_and_points_definition,
        :assert_no_evaluation,
        :assert_no_partitions,
        :assert_no_relations,
        :assert_no_subtours,
        :assert_points_same_definition,

        # Vehicle/route constraints
        :assert_no_ride_constraint,
        :assert_no_service_duration_modifiers,
        :assert_vehicles_no_alternative_skills,
        :assert_vehicles_no_force_start, # Use shift_preference instead
        :assert_vehicles_no_initial_load,
        :assert_vehicles_no_late_multiplier,
        :assert_vehicles_no_overload_multiplier,
        :assert_vehicles_start_or_end,
        :assert_no_overall_duration,
        :assert_no_value_matrix,
        :assert_no_rest,

        # Mission constraints
        :assert_no_activity_with_position,
        :assert_no_empty_or_fill,
        :assert_services_no_late_multiplier,
        :assert_no_complex_setup_durations, # Assume that a sinlge point always have the same setup_duration
        :assert_only_one_visit,

        # Solver
        :assert_no_first_solution_strategy,
        :assert_no_free_approach_or_return,
        :assert_no_planning_heuristic,
        :assert_resolution_duration,
        :assert_solver,
      ]
    end

    def solve(vrp, _job = nil, _thread_proc = nil)
      if vrp.vehicles.empty? || vrp.points.empty? || vrp.services.empty?
        return vrp.empty_solution(:pyvrp)
      end

      problem = pyvrp_problem(vrp)
      result = run_pyvrp(problem, [1, vrp.configuration.resolution.duration.to_f / 1000].max.to_i)

      raise 'No feasible solution found' if !result[:feasible] && result[:routes].blank?

      elapsed_time = result[:runtime]
      @index_hash = @service_index_map.map.with_index{ |service, index|
        next unless service

        [index, service.id]
      }.compact.to_h

      # VRPMTW might require to duplicate services into mutual exclusive groups
      @service_hash = {}
      @service_index_map.each.with_index{ |service, index|
        next unless service

        @service_hash[service.id] = [] if !@service_hash.key?(service.id)
        @service_hash[service.id] << index
      }

      return if !result

      filter_capacity = !result[:feasible]
      routes =
        result[:routes].map{ |route|
          vehicle = vrp.vehicles[route[:vehicle_type]]
          stops = []
          @previous = nil
          # Depot index 0 is a valid PyVRP depot; `if start_depot` would skip it.
          unless route[:start_depot].nil?
            start_stop = read_depot_start(vrp, vehicle, depot_schedule(route[:start_schedule], route[:start_time]))
            stops << start_stop if start_stop
          end

          vehicle = vrp.vehicles[route[:vehicle_type]]
          # Reloads empty the vehicle: capacity must be checked between
          # intermediate depots, not accumulated across the whole route.
          route_loads = Hash.new(0)
          Array(route[:activities]).each { |activity|
            kind = activity[:type].to_s.downcase
            if kind == 'depot'
              route_loads = Hash.new(0)
              reload_stop = read_reload_depot(vrp, vehicle, activity[:idx], activity)
              stops << reload_stop if reload_stop
              next
            end
            next unless %w[client pickup delivery].include?(kind)

            visit_index = activity[:idx]
            service = @service_index_map[visit_index]
            next unless service
            if filter_capacity && !visit_fits_capacity?(vehicle, service, route_loads)
              next
            end

            apply_visit_load!(vehicle, service, route_loads) if filter_capacity
            stops << read_visit(vrp, vehicle, visit_index, activity)
          }

          unless route[:end_depot].nil?
            end_stop = read_depot_end(vrp, vehicle, depot_schedule(route[:end_schedule], route[:end_time]))
            stops << end_stop if end_stop
          end

          complete_pyvrp_route_times!(stops, vehicle)
          Models::Solution::Route.new(
            stops: stops,
            vehicle: vehicle,
            info: Models::Solution::Route::Info.new(
              start_time: stops.first&.info&.begin_time || route[:start_time],
              end_time: stops.last&.info&.end_time || stops.last&.info&.begin_time || route[:end_time]
            )
          )
        }

      unassigneds =
        @service_hash.values.map{ |indices|
          read_unassigned(vrp, indices.first)
        }

      log "Solution cost: #{result[:cost]} & unassigned: #{unassigneds.size}", level: :info

      pyvrp_solution =
        Models::Solution.new(
          elapsed: elapsed_time,
          solvers: [:pyvrp],
          routes: routes,
          unassigned_stops: unassigneds
        )
      pyvrp_solution.parse(vrp, preserve_solver_waiting_times: true)
    end

    def self.seed_vrp_routes_from_solution(vrp, solution)
      new.send(:seed_vrp_routes_from_solution, vrp, solution)
    end

    private

    def depot_schedule(schedule, fallback_time)
      return schedule if schedule.is_a?(Hash) && !schedule[:start_time].nil?

      { start_time: fallback_time, end_time: fallback_time, wait_duration: 0 }
    end

    def solver_schedule(activity)
      start_time = activity && activity[:start_time]
      return {} if start_time.nil?

      end_time = activity[:end_time] || start_time
      {
        begin_time: start_time,
        waiting_time: activity[:wait_duration].to_i,
        end_time: end_time,
        departure_time: end_time
      }
    end

    def complete_pyvrp_route_times!(stops, vehicle)
      stops.each do |stop|
        info = stop.info
        info.waiting_time = 0 if info.waiting_time.nil?
        next unless info.begin_time

        if stop.is_a?(Models::Solution::StopDepot)
          info.end_time ||= info.begin_time
          info.departure_time ||= info.begin_time
          next
        end

        service_duration =
          info.end_time ? info.end_time - info.begin_time : stop.activity.duration_on(vehicle)
        info.end_time ||= info.begin_time + service_duration.to_i
        info.departure_time ||= info.end_time
      end
    end

    def read_visit(vrp, vehicle, visit_index, activity = nil)
      read_activity(vrp, vehicle, visit_index, activity)
    end

    def read_unassigned(vrp, visit_index)
      read_activity(vrp, nil, visit_index)
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

    def read_depot_start(_vrp, vehicle, schedule = nil)
      point = vehicle&.start_point
      return nil if point.nil?

      route_data = {}
      @previous = point

      Models::Solution::StopDepot.new(
        point,
        info: Models::Solution::Stop::Info.new(route_data.merge(solver_schedule(schedule)))
      )
    end

    def read_depot_end(vrp, vehicle, schedule = nil)
      point = vehicle&.end_point
      return nil if point.nil?

      route_data = compute_route_data(vrp, vehicle, point)
      @previous = point

      Models::Solution::StopDepot.new(
        point,
        info: Models::Solution::Stop::Info.new(route_data.merge(solver_schedule(schedule)))
      )
    end

    def read_reload_depot(vrp, vehicle, reload_depot_index, activity = nil)
      reload_depot = @reload_depots[reload_depot_index - @depots.size]
      return nil if reload_depot.nil?

      route_data = compute_route_data(vrp, vehicle, reload_depot.point)

      @previous = reload_depot.point
      Models::Solution::Stop.new(
        reload_depot,
        info: Models::Solution::Stop::Info.new(route_data.merge(solver_schedule(activity))),
        loads: nil
      )
    end

    def read_activity(vrp, vehicle, visit_index, activity = nil)
      service = @service_index_map[visit_index]
      @service_hash.delete(service.id)

      point = service.activity.point
      route_data = compute_route_data(vrp, vehicle, point)
      times = route_data.merge(solver_schedule(activity))
      job_data = Models::Solution::Stop.new(service, info: Models::Solution::Stop::Info.new(times), loads: nil)
      @previous = point
      job_data
    end

    def compute_route_data(vrp, vehicle, point)
      return { travel_time: 0, travel_distance: 0, travel_value: 0 } unless @previous && point.matrix_index

      matrix = vrp.matrices.find{ |m| m.id == vehicle.matrix_id } if vehicle

      {
        travel_time: (matrix && matrix[:time]) ? matrix[:time][@previous.matrix_index][point.matrix_index] : 0,
        travel_distance: (matrix && matrix[:distance]) ? matrix[:distance][@previous.matrix_index][point.matrix_index] : 0,
        travel_value: (matrix && matrix[:value]) ? matrix[:value][@previous.matrix_index][point.matrix_index] : 0
      }
    end

    # Bounded substitutes for MAX_INT64 so PenaltyManager magnitudes stay comparable.
    def max_matrix_cell(vrp, dimension)
      vrp.matrices.filter_map{ |matrix| matrix.send(dimension) }.flat_map(&:flatten).compact.max
    end

    def time_horizon(vrp)
      tw_ends = []
      vrp.vehicles.each{ |vehicle|
        tw_ends << vehicle.timewindow.end if vehicle.timewindow&.end
        tw_ends << vehicle.duration if vehicle.duration
      }
      vrp.services.each{ |service|
        service.activity.timewindows.each{ |tw| tw_ends << tw.end if tw.end }
      }
      vrp.reload_depots.each{ |depot|
        depot.timewindows.each{ |tw| tw_ends << tw.end if tw.end }
      }
      return [tw_ends.max, 1].max if tw_ends.any?

      matrix_bound = max_matrix_cell(vrp, :time)
      service_time =
        vrp.services.sum{ |service|
          service.activity.duration.to_i + service.activity.setup_duration.to_i
        }
      computed = matrix_bound && ((matrix_bound * (vrp.services.size + 2)) + service_time)
      [computed || 86_400, 1].max
    end

    def distance_horizon(vrp)
      vehicle_max = vrp.vehicles.map(&:distance).compact.max
      matrix_bound = max_matrix_cell(vrp, :distance) || max_matrix_cell(vrp, :time)
      # n_services hops is 10^8–10^9 m on large instances. A per-vehicle hop
      # count still leaves slack for unbalanced *and* random infeasible routes
      # (tight hop caps make excess_distance the first PenaltyManager term to
      # saturate on road matrices in metres).
      hops = [(vrp.services.size / [vrp.vehicles.size, 1].max) + 2, 50].max
      computed = [
        vehicle_max,
        matrix_bound && (matrix_bound * hops)
      ].compact.max
      [computed || 1, 1].max
    end

    def unit_demand_totals(vrp)
      totals = Hash.new(0)
      vrp.services.each{ |service|
        pickup, delivery = scaled_pickup_delivery(service)
        (pickup.keys | delivery.keys).each{ |unit_id|
          totals[unit_id] += pickup[unit_id] + delivery[unit_id]
        }
      }
      totals
    end

    def unbounded_unit_capacity(unit_id)
      demand = @unit_demand_totals[unit_id].to_i
      demand.positive? ? demand : 1
    end

    # Load dimensions for skills that actually restrict assignment. Universal
    # tags (every vehicle has them) only inflate PenaltyManager.
    def skill_dimension_index(vrp)
      vehicle_sets = vrp.vehicles.map{ |vehicle| Array(vehicle.skills&.first).to_set }
      service_skills = vrp.services.flat_map(&:skills).uniq
      names =
        service_skills.select{ |skill|
          vehicle_sets.any?{ |set| !set.include?(skill) }
        }
      names.each_with_index.to_h
    end

    def skill_demand_quantity
      CUSTOM_QUANTITY_BIGNUM.round
    end

    def skill_vehicle_capacity(vrp)
      [vrp.services.size, 1].max * skill_demand_quantity
    end

    def service_horizon_past_vehicles?(vrp)
      max_service_end =
        vrp.services.flat_map{ |service|
          service.activity.timewindows.filter_map(&:end)
        }.max
      max_vehicle_end = vrp.vehicles.filter_map{ |vehicle| vehicle.timewindow&.end }.max
      max_service_end && max_vehicle_end && max_service_end > max_vehicle_end
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

    def pyvrp_problem(vrp)
      @service_index_map = []

      # Skills can be considered as capacities
      @skills_index_hash = {}

      # to keep the client and depot indices consistent, the depots should be built before the clients and the matrices
      @point_hash = vrp.points.index_by(&:id)
      @time_horizon = time_horizon(vrp)
      @service_horizon_past_vehicles = service_horizon_past_vehicles?(vrp)
      @distance_horizon = distance_horizon(vrp)
      @unit_demand_totals = unit_demand_totals(vrp)
      prepare_exclusion_costs(vrp)
      log "PyVRP horizons time=#{@time_horizon} distance=#{@distance_horizon}", level: :info
      locations = build_locations(vrp)
      depots = build_depots(vrp)

      @skills_index_hash = skill_dimension_index(vrp)
      used_matrices = vrp.vehicles.map(&:matrix_id).uniq
      matrices = used_matrices.map { |id| vrp.matrices.find { |m| m.id == id } }
      distance_matrices = matrices.map(&:distance).compact
      duration_matrices = matrices.map { |matrix| matrix.time&.map(&:itself) }.compact
      apply_setup_to_duration_matrices(vrp, duration_matrices)

      distance_matrices = duration_matrices if distance_matrices.empty?

      @reload_depot_index_hash = {}
      vrp.reload_depots.each_with_index{ |depot, index| @reload_depot_index_hash[depot.id] = depots.size + index }
      clients, groups = build_clients_and_groups(vrp)
      log "PyVRP locations=#{locations.size} clients=#{clients.size} groups=#{groups.size} " \
          "skill_dims=#{@skills_index_hash.size} unit_dims=#{vrp.units.size} ",
          level: :info
      vehicles = build_vehicles(vrp)
      routes = build_routes(vrp)
      {
        locations: locations,
        depots: depots,
        clients: clients,
        vehicle_types: vehicles,
        distance_matrices: distance_matrices,
        duration_matrices: duration_matrices,
        groups: groups,
        routes: routes
      }.delete_if { |_, v| v.nil? || v.empty? }
    end

    def build_locations(vrp)
      point_by_matrix_index =
        vrp.points.filter_map{ |point|
          next if point.matrix_index.nil?

          [point.matrix_index, point]
        }.to_h
      matrix_indices = point_by_matrix_index.keys.sort
      @matrix_indices = matrix_indices
      @location_by_matrix_index = matrix_indices.each_with_index.to_h
      @location_by_point_id = {}
      vrp.points.each{ |point|
        next if point.matrix_index.nil?

        @location_by_point_id[point.id] = @location_by_matrix_index[point.matrix_index]
      }
      matrix_indices.map{ |matrix_index|
        point = point_by_matrix_index[matrix_index]
        { name: point.id.to_s }
      }
    end

    def location_index_for(point)
      return nil unless point

      @location_by_point_id[point.id]
    end

    def setup_duration_by_matrix_index(vrp)
      setups = {}
      vrp.services.each{ |service|
        matrix_index = service.activity.point&.matrix_index
        next if matrix_index.nil?

        setups[matrix_index] = service.activity.setup_duration.to_i
      }
      setups
    end

    def apply_setup_to_duration_matrices(vrp, duration_matrices)
      setups = setup_duration_by_matrix_index(vrp)
      location_count = @matrix_indices.size
      duration_matrices.map!{ |matrix|
        Array.new(location_count){ |from_loc|
          from_matrix_index = @matrix_indices[from_loc]
          Array.new(location_count){ |to_loc|
            to_matrix_index = @matrix_indices[to_loc]
            travel = matrix[from_matrix_index][to_matrix_index]
            if from_matrix_index != to_matrix_index && setups[to_matrix_index].to_i.positive?
              travel += setups[to_matrix_index].to_i
            end
            travel
          }
        }
      }
    end

    def build_vehicles(vrp)
      used_matrices = vrp.vehicles.map(&:matrix_id).uniq
      all_units = vrp.units.index_by(&:id)

      vrp.vehicles.map { |veh|
        capacity_hash = all_units.map{ |id, _unit| [id, unbounded_unit_capacity(id)] }.to_h
        veh.capacities.each do |capacity|
          capacity_hash[capacity.unit_id] =
            if capacity.limit
              (capacity.limit * CUSTOM_QUANTITY_BIGNUM).round
            else
              unbounded_unit_capacity(capacity.unit_id)
            end
        end

        capacity_skills = Array.new(@skills_index_hash.size, 0)
        Array(veh.skills&.first).each do |skill|
          next unless @skills_index_hash.key?(skill)

          capacity_skills[@skills_index_hash[skill]] = skill_vehicle_capacity(vrp)
        end

        {
          num_available: 1,
          capacity: capacity_hash.values + capacity_skills,
          start_depot: @vehicle_start_point_index_hash[veh.id],
          fixed_cost: veh.cost_fixed.to_i,
          tw_early: veh.timewindow&.start || 0,
          tw_late: veh.timewindow&.end || @time_horizon,
          shift_duration: veh.duration || @time_horizon,
          max_distance: veh.distance || @distance_horizon,
          unit_distance_cost: veh.cost_distance_multiplier.to_i,
          unit_duration_cost: veh.cost_time_multiplier.to_i,
          profile: used_matrices.index(veh.matrix_id),
          start_late: nil,
          reload_depots: veh.reload_depots.map{ |depot| @reload_depot_hash[depot.id] },
          max_reloads: veh.maximum_reloads || 0,
          name: veh.id.to_s
        }.merge(optional_end_depot_hash(veh.id))
      }
    end

    def build_clients_and_groups(vrp)
      all_units = vrp.units.index_by(&:id)
      client_list = []
      groups = []
      service_to_client_indices = {}

      vrp.services.each do |service|
        activity = service.activity
        point = activity.point

        delivery_hash = all_units.map { |id, _| [id, 0] }.to_h
        pickup_hash = all_units.map { |id, _| [id, 0] }.to_h

        service.quantities.each do |quantity|
          delivery_hash[quantity.unit_id] = (quantity.delivery * CUSTOM_QUANTITY_BIGNUM).round if quantity.delivery
          pickup_hash[quantity.unit_id] = (quantity.pickup * CUSTOM_QUANTITY_BIGNUM).round if quantity.pickup

          next if quantity.value.zero?

          if quantity.value < 0
            delivery_hash[quantity.unit_id] = (quantity.value.abs * CUSTOM_QUANTITY_BIGNUM).round
          else
            pickup_hash[quantity.unit_id] = (quantity.value * CUSTOM_QUANTITY_BIGNUM).round
          end
        end

        quantity_skills = Array.new(@skills_index_hash.size, 0)
        service.skills.each do |skill|
          next unless @skills_index_hash.key?(skill)

          quantity_skills[@skills_index_hash[skill]] = skill_demand_quantity
        end
        null_quantity_skills = Array.new(@skills_index_hash.size, 0)

        timewindows =
          if activity.timewindows.empty?
            [Models::Timewindow.new(start: 0, end: @time_horizon)]
          else
            activity.timewindows
          end
        timewindows.each_with_index do |tw, tw_idx|
          client_index = @service_index_map.size
          @service_index_map << service
          client_list << {
            location: location_index_for(point),
            delivery: delivery_hash.values + null_quantity_skills,
            pickup: pickup_hash.values + quantity_skills,
            service_duration: activity.duration.to_i,
            tw_early: tw.start || 0,
            tw_late: tw.end || @time_horizon,
            release_time: 0,
            prize: client_prize(service),
            required: mandatory_service?(service) && timewindows.size <= 1,
            name: "#{service.id}_tw#{tw_idx}"
          }
          service_to_client_indices[service.id] ||= []
          service_to_client_indices[service.id] << client_index
        end
      end

      service_to_client_indices.each do |_service_id, indices|
        next unless indices.size > 1

        service = @service_index_map[indices.first]
        indices.each { |idx| client_list[idx][:group] = groups.size }
        groups << { clients: indices, required: mandatory_service?(service) }
      end

      [client_list, groups]
    end

    def mandatory_service?(service)
      service.priority == 0
    end

    def client_prize(service)
      exclusion_cost_for(service)&.round || 0
    end

    def exclusion_cost_for(service)
      return service.exclusion_cost if service.exclusion_cost
      return if mandatory_service?(service)

      @exclusion_costs.fetch(service.id)
    end

    def prepare_exclusion_costs(vrp)
      @exclusion_costs = {}
      soft_services =
        vrp.services.select{ |service|
          !mandatory_service?(service) && service.exclusion_cost.nil?
        }
      mandatory_count = vrp.services.count{ |service| mandatory_service?(service) }
      log(
        "PyVRP client requirement: #{mandatory_count} mandatory, #{soft_services.size} optional",
        level: :info
      )
      return if soft_services.empty?

      max_fixed = [vrp.vehicles.map(&:cost_fixed).max.to_f, 1.0].max
      unit_time_cost = [vrp.vehicles.map(&:cost_time_multiplier).max.to_f, 1.0].max
      unit_distance_cost = [vrp.vehicles.map(&:cost_distance_multiplier).max.to_f, 1.0].max
      avg_service_duration =
        vrp.services.sum{ |service| service.activity.duration.to_i } /
        [vrp.services.size, 1].max.to_f
      avg_travel = average_depot_travel_seconds(vrp)
      max_roundtrip = max_depot_roundtrip_seconds(vrp)
      marginal_travel_cost = unit_time_cost * (2 * avg_travel + avg_service_duration)
      roundtrip_cost = (unit_time_cost + unit_distance_cost) * max_roundtrip
      density = soft_services.size.to_f / [vrp.vehicles.size, 1].max
      sqrt_density = Math.sqrt(density)
      base_prize = [
        max_fixed * 4 * density,
        max_fixed * 4 * sqrt_density,
        roundtrip_cost * 2,
        roundtrip_cost * density,
        marginal_travel_cost * 2
      ].max.ceil
      priority_four_floor = (max_fixed * 4 * density).ceil

      soft_services.each do |service|
        priority_factor = 2**(4 - service.priority.clamp(0, 8))
        timewindow_count = [service.activity.timewindows.size, 1].max
        prize = (priority_factor * base_prize).ceil
        prize = [prize, priority_four_floor].max if service.priority >= 4
        if timewindow_count > 1
          group_prize = 500_000 * timewindow_count
          prize = [prize, group_prize].max
        end
        @exclusion_costs[service.id] = prize
      end
    end

    def max_depot_roundtrip_seconds(vrp)
      vehicle = vrp.vehicles.first
      depot = vehicle&.start_point
      matrix = vrp.matrices.find{ |entry| entry.id == vehicle&.matrix_id } || vrp.matrices.first
      return 0 unless depot&.matrix_index && matrix&.time

      row = matrix.time[depot.matrix_index]
      return 0 unless row&.any?

      2 * row.compact.max.to_f
    end

    def average_depot_travel_seconds(vrp)
      vehicle = vrp.vehicles.first
      depot = vehicle&.start_point
      matrix = vrp.matrices.find{ |entry| entry.id == vehicle&.matrix_id } || vrp.matrices.first
      return 0 unless depot&.matrix_index && matrix&.time

      row = matrix.time[depot.matrix_index]
      return 0 unless row&.any?

      row.compact.sum.to_f / row.size
    end

    def scaled_capacity_limits(vehicle)
      vehicle.capacities.each_with_object({}) do |capacity, limits|
        limits[capacity.unit_id] = (capacity.limit * CUSTOM_QUANTITY_BIGNUM).round if capacity.limit
      end
    end

    def scaled_pickup_delivery(service)
      pickup = Hash.new(0)
      delivery = Hash.new(0)
      service.quantities.each do |quantity|
        delivery[quantity.unit_id] = (quantity.delivery * CUSTOM_QUANTITY_BIGNUM).round if quantity.delivery
        pickup[quantity.unit_id] = (quantity.pickup * CUSTOM_QUANTITY_BIGNUM).round if quantity.pickup

        next if quantity.value.zero?

        if quantity.value < 0
          delivery[quantity.unit_id] = (quantity.value.abs * CUSTOM_QUANTITY_BIGNUM).round
        else
          pickup[quantity.unit_id] = (quantity.value * CUSTOM_QUANTITY_BIGNUM).round
        end
      end
      [pickup, delivery]
    end

    def visit_fits_capacity?(vehicle, service, route_loads)
      limits = scaled_capacity_limits(vehicle)
      return true if limits.empty?

      pickup, delivery = scaled_pickup_delivery(service)
      limits.all? do |unit_id, limit|
        if delivery[unit_id].positive? && pickup[unit_id].zero?
          (route_loads["delivery_sum:#{unit_id}"] || 0) + delivery[unit_id] <= limit
        else
          (route_loads[unit_id] || 0) + pickup[unit_id] - delivery[unit_id] <= limit &&
            (route_loads[unit_id] || 0) + pickup[unit_id] - delivery[unit_id] >= 0
        end
      end
    end

    def apply_visit_load!(vehicle, service, route_loads)
      pickup, delivery = scaled_pickup_delivery(service)
      scaled_capacity_limits(vehicle).each_key do |unit_id|
        if delivery[unit_id].positive? && pickup[unit_id].zero?
          route_loads["delivery_sum:#{unit_id}"] = (route_loads["delivery_sum:#{unit_id}"] || 0) + delivery[unit_id]
        else
          route_loads[unit_id] = (route_loads[unit_id] || 0) + pickup[unit_id] - delivery[unit_id]
        end
      end
    end

    def seed_vrp_routes_from_solution(vrp, solution)
      vrp.routes =
        solution.routes.filter_map{ |route|
          service_ids = route.stops.filter_map(&:service_id)
          next if service_ids.empty?

          vehicle = route.vehicle
          missions = split_missions_with_reloads(vehicle, service_ids, vrp)
          Models::Route.new(vehicle: vehicle, missions: missions)
        }
    end

    def split_missions_with_reloads(vehicle, service_ids, vrp)
      services_by_id = vrp.services.index_by(&:id)
      reload_depot = vehicle.reload_depots.first
      max_reloads = vehicle.maximum_reloads.to_i
      missions = []
      route_loads = Hash.new(0)
      reloads_used = 0

      service_ids.each{ |service_id|
        service = services_by_id[service_id]
        next unless service

        needs_reload =
          reload_depot &&
          reloads_used < max_reloads &&
          !visit_fits_capacity?(vehicle, service, route_loads)
        if needs_reload
          missions << reload_depot
          route_loads = Hash.new(0)
          reloads_used += 1
        end
        missions << service
        apply_visit_load!(vehicle, service, route_loads)
      }
      missions
    end

    # Open routes have no end_point: omit end_depot and let PyVRP apply its default.
    def optional_end_depot_hash(vehicle_id)
      end_depot = @vehicle_end_point_index_hash[vehicle_id]
      end_depot.nil? ? {} : { end_depot: end_depot }
    end

    def add_depot_point(point, index_hash, criteria = nil)
      return if point.nil?

      return index_hash[point.id] if index_hash.key?(point.id) && index_hash[point.id].is_a?(Integer)

      return index_hash[point.id][criteria] if index_hash[point.id].is_a?(Hash) && index_hash[point.id].key?(criteria)

      @depots << point
      new_idx = @depots.size - 1
      if criteria
        index_hash[point.id] ||= {}
        index_hash[point.id][criteria] = new_idx
      else
        index_hash[point.id] = new_idx
      end
      new_idx
    end

    # Vehicle.shift_preference may be a String from the API or a Symbol from internal hashes — normalize for case/when.
    def normalized_vehicle_shift_preference(vehicle)
      case vehicle.shift_preference.to_s
      when 'force_start'
        :force_start
      when 'force_end'
        :force_end
      else
        :minimize_span
      end
    end

    def build_depots(vrp)
      @depots = []
      @vehicle_start_point_index_hash = {}
      @vehicle_end_point_index_hash = {}
      @depot_points_standard_index_hash = {}
      @depot_points_force_start_by_timewindow_start_index_hash = {}
      @depot_points_force_end_by_timewindow_end_index_hash = {}
      vrp.vehicles.group_by{ |vehicle| normalized_vehicle_shift_preference(vehicle) }.each do |shift_preference, vehicles|
        vehicles.group_by(&:timewindow).each do |timewindow, sub_vehicles|
          case shift_preference
          when :force_start
            sub_vehicles.each do |vehicle|
              @vehicle_start_point_index_hash[vehicle.id] =
                add_depot_point(
                  vehicle.start_point,
                  @depot_points_force_start_by_timewindow_start_index_hash,
                  timewindow.start
                )
              @vehicle_end_point_index_hash[vehicle.id] =
                add_depot_point(vehicle.end_point, @depot_points_standard_index_hash)
            end
          when :force_end
            sub_vehicles.each do |vehicle|
              @vehicle_start_point_index_hash[vehicle.id] =
                add_depot_point(vehicle.start_point, @depot_points_standard_index_hash)
              @vehicle_end_point_index_hash[vehicle.id] =
                add_depot_point(
                  vehicle.end_point,
                  @depot_points_force_end_by_timewindow_end_index_hash,
                  timewindow.end
                )
            end
          when :minimize_span
            sub_vehicles.each do |vehicle|
              @vehicle_start_point_index_hash[vehicle.id] =
                add_depot_point(vehicle.start_point, @depot_points_standard_index_hash)
              @vehicle_end_point_index_hash[vehicle.id] =
                add_depot_point(vehicle.end_point, @depot_points_standard_index_hash)
            end
          end
        end
      end
      depots = Array.new(@depots.size, nil)
      @depot_points_standard_index_hash.map { |point_id, index|
        depots[index] =
          {
            location: location_index_for(@point_hash[point_id]),
            tw_early: 0,
            tw_late: @time_horizon,
            name: "#{point_id}_standard" || '_null_store'
          }
      }
      @depot_points_force_start_by_timewindow_start_index_hash.each do |point_id, tw_start_to_index|
        tw_start_to_index.each do |timewindow_start, point_index|
          depots[point_index] =
            {
              location: location_index_for(@point_hash[point_id]),
              tw_early: timewindow_start || 0,
              tw_late: timewindow_start,
              name: "#{point_id}_#{timewindow_start}_force_start" || '_null_store'
            }
        end
      end
      @depot_points_force_end_by_timewindow_end_index_hash.each do |point_id, tw_end_to_index|
        tw_end_to_index.each do |timewindow_end, point_index|
          depots[point_index] = {
            location: location_index_for(@point_hash[point_id]),
            tw_early: timewindow_end || 0,
            tw_late: timewindow_end || @time_horizon,
            name: "#{point_id}_#{timewindow_end}_force_end" || '_null_store'
          }
        end
      end

      @reload_depots = []
      @reload_depot_hash = {}
      vrp.reload_depots.each do |depot|
        next if @reload_depot_hash.key?(depot.id)

        @reload_depots << depot
        @reload_depot_hash[depot.id] = depots.size
        depots <<
          {
            location: location_index_for(depot.point),
            tw_early: depot.timewindows.first&.start || 0,
            tw_late: depot.timewindows.first&.end || @time_horizon,
            service_duration: depot.duration.to_i,
            name: "reload_#{depot&.id&.to_s || 'null_store'}"
          }
      end
      nil_indices = depots.each_with_index.select{ |slot, _i| slot.nil? }.map(&:last)
      if nil_indices.any?
        log(
          "PyVRP build_depots: #{nil_indices.size} unknown depots at indices #{nil_indices.inspect} — ",
          level: :warn
        )
      end
      depots
    end

    def build_routes(vrp)
      return if vrp.routes.empty?

      vrp.routes.map{ |route|
        next if route.missions.none?{ |mission| mission.is_a?(Models::Service) }

        vehicle_type = vrp.vehicles.find_index{ |v| v.id == route.vehicle.id }
        {
          activities: build_route_activities(route),
          vehicle_type: vehicle_type
        }
      }.compact
    end

    def build_route_activities(route)
      activities = []
      route.missions.each do |mission|
        if mission.is_a?(Models::Service)
          visit_index = @service_index_map.find_index{ |service| service && service.id == mission.id }
          activities << { type: 'client', idx: visit_index } if visit_index
        elsif mission.is_a?(Models::ReloadDepot)
          reload_index = @reload_depot_hash[mission.id]
          activities << { type: 'depot', idx: reload_index } if reload_index
        end
      end
      activities
    end

    def pyvrp_python
      env_python = ENV['PYVRP_PYTHON']
      return env_python if env_python && !env_python.empty?

      venv_python = '/opt/pyenv/bin/python3'
      File.executable?(venv_python) ? venv_python : 'python3'
    end

    def run_pyvrp(problem, timeout = nil)
      input = Tempfile.new('optimize-pyvrp-input', @tmp_dir)

      input.write(problem.to_json)
      input.close

      output = Tempfile.new('optimize-pyvrp-output', @tmp_dir)
      output.close
      cmd = "#{pyvrp_python} wrappers/pyvrp_wrapper.py #{input.path} #{output.path} #{timeout}"
      log cmd
      stdin, stdout_and_stderr, @thread = Open3.popen2e(cmd)

      return if !@thread

      out = ''
      stdout_and_stderr.each_line { |line|
        log line.strip, level: :info
        out += line
      }

      stdin&.close
      stdout_and_stderr&.close

      if @thread.value.success?
        JSON.parse(File.read(output.path), symbolize_names: true)
      else # Fatal Error
        message =
          case @thread.value
          when 127
            'Executable does not exist'
          when 137 # Segmentation Fault
            "SIGKILL received: manual intervention or 'oom-killer' [OUT-OF-MEMORY]"
          else
            "Job terminated with unknown thread status: #{@thread.value}"
          end
        raise message
      end
    ensure
      input&.unlink
      output&.unlink
      stdout_and_stderr&.close
      if @thread&.alive? # Need to kill the job and its children if it is still alive
        child_pids = []
        IO.popen("ps -ef | grep #{@thread.pid}") { |io|
          child_pids = io.readlines.map do |line|
            parts = line.split(/\s+/)
            parts[1].to_i if parts[2] == @thread.pid.to_s
          end.compact || []
        }
        child_pids << @thread.pid
        child_pids.each{ |pid| Process.kill('KILL', pid) }
      end
    end
  end
end
