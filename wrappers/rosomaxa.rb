require './wrappers/wrapper'

module Wrappers
  class Rosomaxa < Wrapper
    QUANTITY_SCALE = 1000
    MAX_I32 = (2**31) - 2
    EPOCH = Time.utc(1970, 1, 1)

    def initialize(hash = {})
      super(hash)
      @exec_rosomaxa = hash[:exec_rosomaxa] || ENV['ROSOMAXA_PATH'] || '/usr/local/bin/vrp-cli'
    end

    def solver_constraints
      super + [
        :assert_vehicles_objective,

        :assert_correctness_matrices_vehicles_and_points_definition,
        :assert_matrix_indices,
        :assert_no_evaluation,
        :assert_no_partitions,
        :assert_no_relations_except_simple_shipments,
        :assert_no_subtours,
        :assert_points_same_definition,

        :assert_no_ride_constraint,
        :assert_no_service_duration_modifiers,
        :assert_vehicles_no_alternative_skills,
        :assert_vehicles_no_force_start,
        :assert_vehicles_no_initial_load,
        :assert_vehicles_no_late_multiplier,
        :assert_vehicles_no_overload_multiplier,
        :assert_vehicles_have_start,
        :assert_no_overall_duration,
        :assert_no_value_matrix,
        :assert_only_simple_rests,
        :assert_reload_depots_indexed,

        :assert_no_activity_with_position,
        :assert_no_empty_or_fill,
        :assert_services_no_late_multiplier,
        :assert_no_complex_setup_durations,
        :assert_only_one_visit,
        :assert_no_mixed_service_quantity,
        :assert_no_exclusion_cost,

        :assert_no_first_solution_strategy,
        :assert_no_free_approach_or_return,
        :assert_no_planning_heuristic,
        :assert_resolution_duration,
        :assert_solver,
      ]
    end

    def solve(vrp, _job = nil, _thread_proc = nil)
      if vrp.vehicles.empty? || vrp.points.empty? || vrp.services.empty?
        return vrp.empty_solution(:rosomaxa)
      end

      tic = Time.now
      problem, matrices = pragmatic_problem(vrp)
      timeout = [1, vrp.configuration.resolution.duration.to_f / 1000].max.to_i
      result = run_rosomaxa(problem, matrices, timeout)
      elapsed = (Time.now - tic) * 1000

      build_solution(vrp, result, elapsed)
    end

    private

    def assert_matrix_indices(vrp)
      vrp.points.all?(&:matrix_index) &&
        vrp.vehicles.all?(&:matrix_id) &&
        vrp.matrices.any?{ |matrix| matrix_table(matrix, :time) || matrix_table(matrix, :distance) }
    end

    def assert_vehicles_have_start(vrp)
      vrp.vehicles.all?(&:start_point)
    end

    def assert_only_simple_rests(vrp)
      vrp.vehicles.all?{ |vehicle|
        vehicle.rests.all?{ |rest|
          !Interpreters::RegulatoryRest.lapse_rest?(rest) &&
            rest.timewindows.size <= 1 &&
            !rest.late_multiplier.to_f.positive? &&
            rest.exclusion_cost.nil?
        }
      }
    end

    def assert_reload_depots_indexed(vrp)
      vrp.reload_depots.all?{ |depot|
        depot.point&.matrix_index &&
          depot.exclusion_cost.nil? &&
          !depot.late_multiplier.to_f.positive?
      }
    end

    def assert_no_mixed_service_quantity(vrp)
      vrp.services.none?{ |service|
        pickup, delivery = split_quantities(service)
        pickup.values.any?(&:positive?) && delivery.values.any?(&:positive?)
      }
    end

    def pragmatic_problem(vrp)
      prepare_locations!(vrp)
      @unit_ids = active_unit_ids(vrp)
      @demand_totals = demand_totals(vrp, @unit_ids)
      @horizon = time_horizon(vrp)
      matrices = build_matrices(vrp)
      problem = {
        plan: {
          jobs: build_jobs(vrp)
        },
        fleet: {
          vehicles: vrp.vehicles.map{ |vehicle| build_vehicle(vehicle) },
          profiles: matrices.map{ |matrix| { name: matrix[:profile] } }
        }
      }
      [problem, matrices]
    end

    def prepare_locations!(vrp)
      indices = vrp.points.map(&:matrix_index)
      indices += vrp.reload_depots.map{ |depot| depot.point&.matrix_index }
      @matrix_indices = indices.compact.uniq.sort
      @location_by_matrix_index = @matrix_indices.each_with_index.to_h
      @services_by_tag = {}
      @services_by_job_id = {}
      @rests_by_tag = {}
      @reloads_by_tag = {}
    end

    def location_index(point)
      @location_by_matrix_index[point.matrix_index]
    end

    def active_unit_ids(vrp)
      ids = vrp.units.map(&:id)
      return [] if ids.empty?

      used =
        vrp.services.any?{ |service|
          pickup, delivery = split_quantities(service)
          (pickup.values + delivery.values).any?(&:positive?)
        }
      used ? ids : []
    end

    def demand_totals(vrp, unit_ids)
      totals = Hash.new(0)
      vrp.services.each{ |service|
        pickup, delivery = split_quantities(service)
        unit_ids.each{ |unit_id| totals[unit_id] += pickup[unit_id] + delivery[unit_id] }
      }
      totals
    end

    def build_matrices(vrp)
      vrp.vehicles.map(&:matrix_id).uniq.map{ |matrix_id|
        matrix = vrp.matrices.find{ |item| item.id == matrix_id }
        unless matrix
          raise OptimizerWrapper::UnsupportedProblemError.new("Rosomaxa - missing matrix #{matrix_id}")
        end

        time = matrix_table(matrix, :time)
        distance = matrix_table(matrix, :distance)
        time ||= distance
        distance ||= time
        unless time
          raise OptimizerWrapper::UnsupportedProblemError.new("Rosomaxa - matrix #{matrix_id} has no time or distance")
        end

        travel_times = flat_cells(time, @matrix_indices)
        add_setup!(travel_times, setups_for(vrp, matrix_id))
        {
          profile: matrix_id.to_s,
          travelTimes: travel_times,
          distances: flat_cells(distance, @matrix_indices)
        }
      }
    end

    def matrix_table(matrix, dimension)
      table = matrix.send(dimension)
      table if table.is_a?(Array) && table.any?
    end

    def flat_cells(table, indices)
      indices.flat_map{ |from|
        row = table[from] || []
        indices.map{ |to| row[to].to_i }
      }
    end

    def setups_for(vrp, matrix_id)
      vehicle = vrp.vehicles.find{ |item| item.matrix_id == matrix_id }
      setups = {}
      vrp.services.each{ |service|
        point = service.activity&.point
        next unless point&.matrix_index

        setups[point.matrix_index] = service.activity.setup_duration_on(vehicle).to_i
      }
      setups
    end

    def add_setup!(flat, setups)
      count = @matrix_indices.size
      @matrix_indices.each_with_index{ |to_index, to_loc|
        extra = setups[to_index].to_i
        next unless extra.positive?

        count.times{ |from_loc|
          next if from_loc == to_loc

          flat[(from_loc * count) + to_loc] += extra
        }
      }
      flat
    end

    def build_vehicle(vehicle)
      payload = {
        typeId: vehicle.id.to_s,
        vehicleIds: [vehicle.id.to_s],
        profile: { matrix: vehicle.matrix_id.to_s },
        costs: {
          fixed: vehicle.cost_fixed.to_f,
          distance: vehicle.cost_distance_multiplier.to_f,
          time: vehicle.cost_time_multiplier.to_f
        },
        shifts: [shift_for(vehicle)],
        capacity: capacity_vector(vehicle)
      }
      skill_names = Array(vehicle.skills&.first).map(&:to_s)
      payload[:skills] = skill_names if skill_names.any?
      limits = {}
      limits[:maxDistance] = vehicle.distance.to_f if vehicle.distance
      limits[:maxDuration] = vehicle.duration.to_f if vehicle.duration
      payload[:limits] = limits if limits.any?
      payload
    end

    def shift_for(vehicle)
      start_seconds = vehicle.timewindow&.start || 0
      shift = {
        start: {
          earliest: rfc3339(start_seconds),
          location: { index: location_index(vehicle.start_point) }
        }
      }
      breaks = lunch_breaks(vehicle)
      shift[:breaks] = breaks if breaks.any?
      reloads = reload_places(vehicle)
      shift[:reloads] = reloads if reloads.any?
      return shift unless vehicle.end_point

      latest = vehicle.timewindow&.end
      if vehicle.duration
        duration_latest = start_seconds + vehicle.duration
        latest = latest ? [latest, duration_latest].min : duration_latest
      end
      latest ||= start_seconds + @horizon
      shift[:end] = {
        latest: rfc3339(latest),
        location: { index: location_index(vehicle.end_point) }
      }
      shift
    end

    def capacity_vector(vehicle)
      return [0] if @unit_ids.empty?

      @unit_ids.map{ |unit_id|
        capacity = vehicle.capacities.find{ |cap| cap.unit_id == unit_id }
        if capacity&.limit
          scale(capacity.limit)
        else
          [@demand_totals[unit_id].to_i, 1].max
        end
      }
    end

    def reload_places(vehicle)
      return [] if vehicle.maximum_reloads == 0

      vehicle.reload_depots.filter_map{ |depot|
        next unless depot.point

        @reloads_by_tag[depot.id.to_s] = depot
        place = {
          location: { index: location_index(depot.point) },
          duration: depot.duration.to_f,
          tag: depot.id.to_s
        }
        times = windows_for(depot.timewindows)
        place[:times] = times if times.any?
        place
      }
    end

    def lunch_breaks(vehicle)
      Interpreters::RegulatoryRest.solver_rests(vehicle).map{ |rest|
        @rests_by_tag[rest.id.to_s] = rest
        tw = rest.timewindows.first
        earliest = tw&.start || vehicle.timewindow&.start || 0
        latest = tw&.end || vehicle.timewindow&.end || (earliest + @horizon)
        {
          time: [rfc3339(earliest), rfc3339(latest)],
          places: [{ duration: rest.duration.to_f, tag: rest.id.to_s }]
        }
      }
    end

    def build_jobs(vrp)
      shipped = {}
      jobs = []
      vrp.relations.each{ |relation|
        next unless relation.type == :shipment && relation.linked_services.size == 2

        pickup, delivery = relation.linked_services
        shipped[pickup.id] = true
        shipped[delivery.id] = true
        jobs << shipment_job(relation, pickup, delivery)
      }
      vrp.services.each{ |service|
        next if shipped[service.id]

        jobs << build_job(service)
      }
      jobs
    end

    def shipment_job(relation, pickup, delivery)
      job_id = relation.id.to_s
      job_id = "shipment_#{pickup.id}_#{delivery.id}" if job_id.empty?
      @services_by_job_id[job_id] = [pickup, delivery]
      @services_by_tag[pickup.id.to_s] = pickup
      @services_by_tag[delivery.id.to_s] = delivery
      pickup_qty, = split_quantities(pickup)
      _, delivery_qty = split_quantities(delivery)
      job = {
        id: job_id,
        pickups: [{
          places: [place_for(pickup.activity, tag: pickup.id)],
          demand: demand_vector(pickup_qty)
        }],
        deliveries: [{
          places: [place_for(delivery.activity, tag: delivery.id)],
          demand: demand_vector(delivery_qty)
        }]
      }
      skill_names = (pickup.skills + delivery.skills).map(&:to_s).uniq
      job[:skills] = { allOf: skill_names } if skill_names.any?
      job
    end

    def build_job(service)
      @services_by_job_id[service.id.to_s] = [service]
      pickup, delivery = split_quantities(service)
      task = { places: [place_for(service.activity)] }
      job = { id: service.id.to_s }
      if @unit_ids.any? && delivery.values.any?(&:positive?)
        task[:demand] = demand_vector(delivery)
        job[:deliveries] = [task]
      elsif @unit_ids.any? && pickup.values.any?(&:positive?)
        task[:demand] = demand_vector(pickup)
        job[:pickups] = [task]
      else
        job[:services] = [task]
      end
      skill_names = service.skills.map(&:to_s)
      job[:skills] = { allOf: skill_names } if skill_names.any?
      job
    end

    def demand_vector(by_unit)
      @unit_ids.map{ |unit_id| by_unit[unit_id].to_i }
    end

    def place_for(activity, tag: nil)
      place = {
        location: { index: location_index(activity.point) },
        duration: activity.duration.to_f
      }
      times = windows_for(activity.timewindows)
      place[:times] = times if times.any?
      place[:tag] = tag.to_s if tag
      place
    end

    def windows_for(timewindows)
      timewindows.filter_map{ |tw|
        next if tw.start.nil? && tw.end.nil?

        [rfc3339(tw.start || 0), rfc3339(tw.end || @horizon)]
      }
    end

    def split_quantities(service)
      pickup = Hash.new(0)
      delivery = Hash.new(0)
      service.quantities.each{ |quantity|
        unit_id = quantity.unit_id
        delivery[unit_id] = scale(quantity.delivery) if quantity.delivery
        pickup[unit_id] = scale(quantity.pickup) if quantity.pickup
        next if quantity.value.to_f.zero?

        if quantity.value < 0
          delivery[unit_id] = scale(quantity.value.abs)
        else
          pickup[unit_id] = scale(quantity.value)
        end
      }
      [pickup, delivery]
    end

    def scale(value)
      (value.to_f * QUANTITY_SCALE).round.clamp(0, MAX_I32)
    end

    def time_horizon(vrp)
      ends = []
      vrp.vehicles.each{ |vehicle|
        ends << vehicle.timewindow.end if vehicle.timewindow&.end
        ends << (vehicle.timewindow&.start || 0) + vehicle.duration if vehicle.duration
      }
      vrp.services.each{ |service|
        service.activity&.timewindows&.each{ |tw| ends << tw.end if tw.end }
      }
      [ends.max || 86_400, 1].max
    end

    def rfc3339(seconds)
      (EPOCH + seconds.to_i).iso8601
    end

    def parse_clock(value)
      return nil if value.nil? || value == ''

      Time.iso8601(value).to_i
    end

    def run_rosomaxa(problem, matrices, timeout)
      input = nil
      output = nil
      matrix_files = []
      input = Tempfile.new('optimize-rosomaxa-problem', @tmp_dir)
      input.write(problem.to_json)
      input.close

      matrices.each{ |matrix|
        file = Tempfile.new('optimize-rosomaxa-matrix', @tmp_dir)
        file.write(matrix.to_json)
        file.close
        matrix_files << file
      }

      output = Tempfile.new('optimize-rosomaxa-output', @tmp_dir)
      output.close

      matrix_args = matrix_files.map{ |file| "-m '#{file.path}'" }.join(' ')
      cmd = "#{@exec_rosomaxa} solve pragmatic '#{input.path}' #{matrix_args} --max-time=#{timeout} -o '#{output.path}'"
      log cmd
      _stdout, stderr, status = Open3.capture3(cmd)
      unless status.success?
        raise OptimizerWrapper::UnsupportedProblemError.new("Rosomaxa - #{stderr}")
      end

      JSON.parse(File.read(output.path), symbolize_names: true)
    ensure
      input&.unlink
      output&.unlink
      matrix_files&.each(&:unlink)
    end

    def build_solution(vrp, result, elapsed)
      services_by_id = vrp.services.index_by{ |service| service.id.to_s }
      vehicles_by_id = vrp.vehicles.index_by{ |vehicle| vehicle.id.to_s }
      assigned = {}

      routes =
        Array(result[:tours]).filter_map{ |tour|
          vehicle = vehicles_by_id[tour[:vehicleId]]
          next unless vehicle

          @previous = nil
          stops = []
          Array(tour[:stops]).each{ |raw_stop|
            arrival = parse_clock(raw_stop.dig(:time, :arrival))
            departure = parse_clock(raw_stop.dig(:time, :departure))
            Array(raw_stop[:activities]).each_with_index{ |activity, index|
              case activity[:type].to_s
              when 'departure'
                depot = read_depot(vrp, vehicle, vehicle.start_point, arrival, departure)
                stops << depot if depot
              when 'arrival'
                depot = read_depot(vrp, vehicle, vehicle.end_point, arrival, departure)
                stops << depot if depot
              when 'delivery', 'pickup', 'service', 'replacement'
                service = service_for_activity(activity, services_by_id)
                next unless service
                next if assigned[service.id]

                assigned[service.id] = true
                stops << read_visit(vrp, vehicle, service, activity, arrival, departure, index.zero?)
              when 'reload'
                depot = @reloads_by_tag[activity[:jobTag].to_s]
                next unless depot

                stops << read_timed_stop(
                  vrp, vehicle, depot, depot.point, activity,
                  { arrival: arrival, departure: departure, travel: index.zero? }
                )
              when 'break'
                rest = @rests_by_tag[activity[:jobTag].to_s]
                next unless rest

                point = index.zero? ? point_at(vrp, raw_stop[:location]) : nil
                stops << read_timed_stop(
                  vrp, vehicle, rest, point, activity,
                  { arrival: arrival, departure: departure, travel: !point.nil? }
                )
              end
            }
          }
          next if stops.empty?

          Models::Solution::Route.new(
            stops: stops,
            vehicle: vehicle,
            info: Models::Solution::Route::Info.new(
              start_time: stops.first&.info&.begin_time,
              end_time: stops.last&.info&.end_time || stops.last&.info&.begin_time
            )
          )
        }

      unassigned = []
      Array(result[:unassigned]).each{ |job|
        services = @services_by_job_id[job[:jobId]] || Array(services_by_id[job[:jobId]])
        services.each{ |service|
          next if assigned[service.id]

          assigned[service.id] = true
          unassigned << read_unassigned(service)
        }
      }
      vrp.services.each{ |service|
        next if assigned[service.id]

        unassigned << read_unassigned(service)
      }

      log "Solution cost: #{result.dig(:statistic, :cost)} & unassigned: #{unassigned.size}", level: :info

      solution =
        Models::Solution.new(
          elapsed: elapsed,
          solvers: [:rosomaxa],
          routes: routes,
          unassigned_stops: unassigned
        )
      solution.parse(vrp, preserve_solver_waiting_times: true)
    end

    def read_depot(vrp, vehicle, point, arrival, departure)
      return nil unless point

      route_data = compute_route_data(vrp, vehicle, point)
      @previous = point
      Models::Solution::StopDepot.new(
        point,
        info: Models::Solution::Stop::Info.new(
          route_data.merge(
            begin_time: arrival,
            end_time: departure,
            departure_time: departure,
            waiting_time: 0
          )
        )
      )
    end

    def service_for_activity(activity, services_by_id)
      tagged = @services_by_tag[activity[:jobTag].to_s] if activity[:jobTag]
      tagged || services_by_id[activity[:jobId]]
    end

    def point_at(vrp, location)
      index = location.is_a?(Hash) ? location[:index] : nil
      return nil if index.nil?

      origin = @matrix_indices[index]
      vrp.points.find{ |point| point.matrix_index == origin }
    end

    def read_timed_stop(vrp, vehicle, mission, point, activity, timing)
      arrival = timing[:arrival]
      departure = timing[:departure]
      count_travel = timing[:travel]
      route_data =
        if count_travel && point
          compute_route_data(vrp, vehicle, point)
        else
          { travel_time: 0, travel_distance: 0, travel_value: 0 }
        end
      @previous = point if count_travel && point
      begin_time = activity.dig(:time, :start) ? parse_clock(activity[:time][:start]) : arrival
      end_time = activity.dig(:time, :end) ? parse_clock(activity[:time][:end]) : departure
      waiting = count_travel && begin_time && arrival ? [begin_time - arrival, 0].max : 0
      Models::Solution::Stop.new(
        mission,
        info: Models::Solution::Stop::Info.new(
          route_data.merge(
            begin_time: begin_time,
            end_time: end_time,
            departure_time: end_time,
            waiting_time: waiting
          )
        )
      )
    end

    def read_visit(vrp, vehicle, service, activity, arrival, departure, first_activity)
      point = service.activity.point
      route_data =
        if first_activity
          compute_route_data(vrp, vehicle, point)
        else
          { travel_time: 0, travel_distance: 0, travel_value: 0 }
        end
      begin_time = activity.dig(:time, :start) ? parse_clock(activity[:time][:start]) : arrival
      end_time = activity.dig(:time, :end) ? parse_clock(activity[:time][:end]) : departure
      waiting = first_activity && begin_time && arrival ? [begin_time - arrival, 0].max : 0
      @previous = point
      Models::Solution::Stop.new(
        service,
        info: Models::Solution::Stop::Info.new(
          route_data.merge(
            begin_time: begin_time,
            end_time: end_time,
            departure_time: end_time,
            waiting_time: waiting
          )
        )
      )
    end

    def read_unassigned(service)
      Models::Solution::Stop.new(
        service,
        info: Models::Solution::Stop::Info.new(
          travel_time: 0,
          travel_distance: 0,
          travel_value: 0
        )
      )
    end

    def compute_route_data(vrp, vehicle, point)
      return { travel_time: 0, travel_distance: 0, travel_value: 0 } unless @previous && point&.matrix_index

      matrix = vrp.matrices.find{ |item| item.id == vehicle.matrix_id } if vehicle
      {
        travel_time: matrix&.time ? matrix.time[@previous.matrix_index][point.matrix_index] : 0,
        travel_distance: matrix&.distance ? matrix.distance[@previous.matrix_index][point.matrix_index] : 0,
        travel_value: matrix&.value ? matrix.value[@previous.matrix_index][point.matrix_index] : 0
      }
    end
  end
end
