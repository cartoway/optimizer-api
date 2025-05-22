require './wrappers/wrapper'

module Wrappers
  class PyVRP < Wrapper
    MAX_INT32 = 2**31 - 1
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
        :assert_vehicles_no_force_start,
        :assert_vehicles_no_late_multiplier,
        :assert_vehicles_no_overload_multiplier,
        :assert_vehicles_no_skills,
        :assert_vehicles_start_or_end,
        :assert_no_overall_duration,
        :assert_no_value_matrix,

        # Mission constraints
        :assert_no_activity_with_position,
        :assert_no_empty_or_fill,
        :assert_no_exclusion_cost,
        :assert_no_complex_setup_durations,
        :assert_services_no_late_multiplier,
        :assert_only_one_visit,

        # Solver
        :assert_end_optimization,
        :assert_no_first_solution_strategy,
        :assert_no_free_approach_or_return,
        :assert_no_planning_heuristic,
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

    def solve(vrp, _job = nil, _thread_proc = nil)
      if vrp.vehicles.empty? || vrp.points.empty? || vrp.services.empty?
        return vrp.empty_solution(:pyvrp)
      end

      problem = pyvrp_problem(vrp)
      puts problem.inspect
      result = run_pyvrp(problem, [1, vrp.configuration.resolution.duration.to_f / 1000].max)
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

      routes =
        result[:routes].map{ |route|
          vehicle = vrp.vehicles[route[:vehicle_type]]
          stops = []
          @previous = nil
          if route[:start_depot]
            start_stop = read_depot_start(vrp, vehicle)
            stops << start_stop if start_stop
          end

          vehicle = vrp.vehicles[route[:vehicle_type]]
          stops += route[:visits].map{ |visit_index|
            read_visit(vrp, vehicle, visit_index)
          }.compact

          if route[:end_depot]
            end_stop = read_depot_end(vrp, vehicle)
            stops << end_stop if end_stop
          end

          Models::Solution::Route.new(
            stops: stops,
            vehicle: vehicle,
            info: Models::Solution::Route::Info.new(
              start_time: route[:start_time],
              end_time: route[:end_time]
            )
          )
        }

      unassigneds =
        @service_hash.values.map{ |indices|
          read_unassigned(vrp, indices.first)
        }

      log "Solution cost: #{result[:cost]} & unassigned: #{unassigneds.size}", level: :info

      solution =
        Models::Solution.new(
          elapsed: elapsed_time,
          solvers: [:pryvrp],
          routes: routes,
          unassigned_stops: unassigneds
        )
      solution.parse(vrp)
    end

    private

    def read_visit(vrp, vehicle, visit_index)
      read_activity(vrp, vehicle, visit_index)
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

    def read_depot_start(_vrp, vehicle)
      point = vehicle&.start_point
      return nil if point.nil?

      route_data = {}
      @previous = point

      Models::Solution::StopDepot.new(point, info: Models::Solution::Stop::Info.new(route_data))
    end

    def read_depot_end(vrp, vehicle)
      point = vehicle&.end_point
      return nil if point.nil?

      route_data = compute_route_data(vrp, vehicle, point)
      @previous = point

      Models::Solution::StopDepot.new(point, info: Models::Solution::Stop::Info.new(route_data))
    end

    def read_activity(vrp, vehicle, visit_index)
      service = @service_index_map[visit_index]
      @service_hash.delete(service.id)

      point = service.activity.point
      route_data = compute_route_data(vrp, vehicle, point)
      # begin_time = act_step['arrival'] && (act_step['arrival'] + act_step['waiting_time'] + act_step['setup'])
      times = route_data
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

    def compute_route_data(vrp, vehicle, point)
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

    def pyvrp_problem(vrp)
      @service_index_map = []
      used_matrices = vrp.vehicles.map(&:matrix_id).uniq
      matrices = used_matrices.map { |id| vrp.matrices.find { |m| m.id == id } }
      distance_matrices = matrices.map(&:distance).compact
      duration_matrices = matrices.map(&:time).compact
      expand_matrices(vrp, distance_matrices, duration_matrices)

      distance_matrices = duration_matrices if distance_matrices.empty?
      {
        depots: build_depots(vrp),
        clients: build_clients(vrp),
        vehicle_types: build_vehicles(vrp),
        distance_matrices: distance_matrices,
        duration_matrices: duration_matrices
      }.delete_if { |_, v| v.nil? || v.empty? }
    end

    def expand_matrices(vrp, distance_matrices, duration_matrices)
      depot_points =
        vrp.vehicles.flat_map{ |veh|
          [veh.start_point, veh.end_point]
        }.uniq
      client_points =
        vrp.services.flat_map{ |service|
          [service.activity.point]
        }

      all_points = (depot_points + client_points)

      distance_matrices.map! do |matrix|
        matrix =
          Array.new(all_points.size) { |i|
            Array.new(all_points.size) { |j|
              distance(matrix, all_points[i], all_points[j])
            }
          }
      end

      duration_matrices.map! do |matrix|
        matrix =
          Array.new(all_points.size) { |i|
            Array.new(all_points.size) { |j|
              distance(matrix, all_points[i], all_points[j])
            }
          }
      end
    end

    def distance(matrix, point1, point2)
      return 0 if point1.nil? || point2.nil?

      matrix[point1.matrix_index][point2.matrix_index]
    end

    def build_vehicles(vrp)
      used_matrices = vrp.vehicles.map(&:matrix_id).uniq
      depot_hash =
        vrp.vehicles.flat_map{ |veh|
          [veh.start_point, veh.end_point]
        }.uniq.each_with_index.map { |pt, idx| [pt&.id, idx] }.to_h
      all_units = vrp.units.index_by(&:id)

      vrp.vehicles.map { |veh|
        capacity_hash = all_units.map{ |id, _unit| [id, MAX_INT64] }.to_h
        limit_hash = all_units.map{ |id, _unit| [id, MAX_INT64] }.to_h
        veh.capacities.each do |capacity|
          capacity_hash[capacity.unit_id] = capacity.limit&.to_i || MAX_INT64
          limit_hash[capacity.unit_id] = capacity.initial&.to_i || capacity.limit&.to_i || MAX_INT64
        end
        {
          num_available: 1,
          capacity: capacity_hash.values,
          start_depot: depot_hash[veh.start_point&.id],
          end_depot: depot_hash[veh.end_point&.id],
          fixed_cost: veh.cost_fixed.to_i,
          tw_early: veh.timewindow&.start || 0,
          tw_late: veh.timewindow&.end || MAX_INT64,
          max_duration: veh.duration || MAX_INT64,
          max_distance: veh.distance || MAX_INT64,
          unit_distance_cost: veh.cost_distance_multiplier.to_i,
          unit_duration_cost: veh.cost_time_multiplier.to_i,
          profile: used_matrices.index(veh.matrix_id),
          start_late: nil,
          initial_load: limit_hash.values,
          reload_depots: [],
          max_reloads: MAX_INT64,
          name: veh.id.to_s
        }
      }
    end

    def build_clients(vrp)
      all_units = vrp.units.index_by(&:id)
      vrp.services.map { |service|
        @service_index_map << service
        activity = service.activity
        point = activity.point
        location = point.location

        delivery_hash = all_units.map{ |id, _unit| [id, 0] }.to_h
        pickup_hash = all_units.map{ |id, _unit| [id, 0] }.to_h

        service.quantities.each do |quantity|
          if quantity.value < 0
            delivery_hash[quantity.unit_id] = quantity.value.abs.to_i
          else
            pickup_hash[quantity.unit_id] = quantity.value.to_i
          end
        end

        {
          x: location&.lon || 0,
          y: location&.lat || 0,
          delivery: delivery_hash.values,
          pickup: pickup_hash.values,
          service_duration: activity.duration.to_i,
          tw_early: activity.timewindows.first&.start || 0,
          tw_late: activity.timewindows.first&.end || MAX_INT64,
          release_time: 0,
          prize: service.exclusion_cost || (MAX_INT32 / (service.priority + 1)),
          required: service.priority == 0,
          group: nil,
          name: service.id.to_s
        }
      }
    end

    def build_depots(vrp)
      depot_points = vrp.vehicles.flat_map { |vehicle| [vehicle.start_point, vehicle.end_point] }.uniq
      @service_index_map += depot_points.map{ nil }
      depot_points.map do |point|
        {
          x: point&.location&.lon || 0,
          y: point&.location&.lat || 0,
          tw_early: 0,
          tw_late: MAX_INT64,
          name: point&.id&.to_s || '_null_store'
        }
      end
    end

    def run_pyvrp(problem, timeout = nil)
      input = Tempfile.new('optimize-pyvrp-input', @tmp_dir)

      input.write(problem.to_json)
      input.close

      output = Tempfile.new('optimize-pyvrp-output', @tmp_dir)
      output.close
      cmd = "python3 wrappers/pyvrp_wrapper.py #{input.path} #{output.path} #{timeout}"
      log cmd
      stdout, stderr, status = Open3.capture3(cmd)
      puts "PYTHON STDOUT:\n#{stdout}" unless stdout.empty?
      puts "PYTHON STDERR:\n#{stderr}" unless stderr.empty?

      raise OptimizerWrapper::UnsupportedProblemError.new("PyVRP - #{stderr[8..]}") if !status.success?

      puts status.inspect
      JSON.parse(File.read(output.path), symbolize_names: true) if status.exitstatus.zero?
    ensure
      input&.unlink
      output&.unlink
    end
  end
end
