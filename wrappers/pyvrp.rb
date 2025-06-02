require './wrappers/wrapper'

module Wrappers
  class PyVRP < Wrapper
    CUSTOM_QUANTITY_BIGNUM = 1e3
    MAX_INT32 = 2**31 - 1
    MAX_INT64 = 2**63 - 1
    MAX_INT_UNITS = 2**60 - 1

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
        :assert_vehicles_no_initial_load,
        :assert_vehicles_no_late_multiplier,
        :assert_vehicles_no_overload_multiplier,
        # :assert_vehicles_no_skills,
        :assert_vehicles_start_or_end,
        :assert_no_overall_duration,
        :assert_no_value_matrix,

        # Mission constraints
        :assert_no_activity_with_position,
        :assert_no_empty_or_fill,
        :assert_no_exclusion_cost,
        :assert_services_no_late_multiplier,
        :assert_services_no_setup_duration,
        :assert_only_one_visit,

        # Solver
        :assert_no_first_solution_strategy,
        :assert_no_free_approach_or_return,
        :assert_no_planning_heuristic,
        :assert_resolution_duration,
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
      result = run_pyvrp(problem, [1, vrp.configuration.resolution.duration.to_f / 1000].max.to_i)
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

      # to keep the client indices consistent, the depots should be built before the clients
      depots = build_depots(vrp)
      clients, groups = build_clients_and_groups(vrp)
      {
        depots: depots,
        clients: clients,
        vehicle_types: build_vehicles(vrp),
        distance_matrices: distance_matrices,
        duration_matrices: duration_matrices,
        groups: groups
      }.delete_if { |_, v| v.nil? || v.empty? }
    end

    def expand_matrices(vrp, distance_matrices, duration_matrices)
      depot_points =
        vrp.vehicles.flat_map{ |veh|
          [veh.start_point, veh.end_point]
        }.uniq
      client_points =
        vrp.services.flat_map{ |service|
          (service.activity.timewindows.empty? ? [nil] : service.activity.timewindows).map{ |_tw|
            service.activity.point
          }
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
          capacity_hash[capacity.unit_id] =
            (capacity.limit && (capacity.limit * CUSTOM_QUANTITY_BIGNUM).to_i || MAX_INT_UNITS)
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
          reload_depots: [],
          max_reloads: MAX_INT64,
          name: veh.id.to_s
        }
      }
    end

    def build_clients_and_groups(vrp)
      all_units = vrp.units.index_by(&:id)
      client_list = []
      groups = []
      service_to_client_indices = {}
      depot_size = @service_index_map.size

      vrp.services.each do |service|
        activity = service.activity
        point = activity.point
        location = point.location

        delivery_hash = all_units.map { |id, _| [id, 0] }.to_h
        pickup_hash = all_units.map { |id, _| [id, 0] }.to_h

        service.quantities.each do |quantity|
          if quantity.value < 0
            delivery_hash[quantity.unit_id] = (quantity.value.abs * CUSTOM_QUANTITY_BIGNUM).round
          else
            pickup_hash[quantity.unit_id] = (quantity.value * CUSTOM_QUANTITY_BIGNUM).round
          end
        end
        timewindows =
          if activity.timewindows.empty?
            [Models::Timewindow.new(start: 0, end: MAX_INT64)]
          else
            activity.timewindows
          end
        timewindows.each_with_index do |tw, tw_idx|
          client_index = @service_index_map.size
          @service_index_map << service
          client_list << {
            x: location&.lon || 0,
            y: location&.lat || 0,
            delivery: delivery_hash.values,
            pickup: pickup_hash.values,
            service_duration: activity.duration.to_i,
            tw_early: tw.start || 0,
            tw_late: tw.end || MAX_INT64,
            release_time: 0,
            prize: service.exclusion_cost || (MAX_INT32 / (service.priority + 1)),
            required: service.priority == 0 && activity.timewindows.size <= 1,
            name: "#{service.id}_tw#{tw_idx}"
          }
          service_to_client_indices[service.id] ||= []
          service_to_client_indices[service.id] << client_index
        end
      end

      service_to_client_indices.each do |_service_id, indices|
        next unless indices.size > 1

        indices.each { |idx| client_list[idx - depot_size][:group] = groups.size }
        groups << { clients: indices, required: false }
      end

      [client_list, groups]
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
