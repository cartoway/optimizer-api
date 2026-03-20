require './lib/vrp_graph'
require './lib/interpreters/split_clustering'
require './api/v01/api_base'

module Interpreters
  class RePartition
    # Raised when a candidate solution assigns the same mission more often than allowed or mixes assigned/unassigned.
    class DuplicateAssignmentError < StandardError; end

    # Shared-neighbor counts are raised to this power before roulette sampling.
    # 1.0 = linear, < 1.0 reduces probability advantage of route neighbors.
    NEIGHBOR_WEIGHT_POWER = 0.55

    class << self
      def repartition(service_vrp, job = nil, &block)
        return nil unless candidate?(service_vrp)

        vrp = service_vrp.vrp

        # Number of repartition iterations (excluding the initial solution).
        max_iterations = 4

        iteration_duration =
          if vrp.configuration.resolution.duration
            (vrp.configuration.resolution.duration / (max_iterations + 1).to_f).floor
          end

        graph = build_graph(vrp)
        return nil unless graph

        repartition_default_json = build_default_service_vrp_json(service_vrp)

        initial_solution = initialize_resolution(repartition_default_json, iteration_duration)
        return nil unless initial_solution

        validate_repartition_solution_no_duplicates!(initial_solution, vrp, 'RePartition initial solution')

        log "RePartition initial solution: #{initial_solution.routes.size} routes", level: :info

        best_solution = initial_solution
        best_score = score_solution(best_solution, vrp)

        max_iterations.times do |iter|
          improved_solution =
            repartition_once(
              repartition_context_payload, graph, best_solution, job, iteration_duration,
              iteration_index: iter,
              &block
            )
          improved_score = score_solution(improved_solution, vrp)

          log "RePartition current best score: #{best_score[0]} unassigned, #{best_score[1]} cost", level: :info
          unless better_score?(improved_score, best_score)
            next
          end

          log "RePartition improved solution: #{improved_score[0]} unassigned, #{improved_score[1]} cost", level: :info

          best_solution = improved_solution
          best_score = improved_score
        end

        best_solution
      end

      private

      def initialize_resolution(repartition_default_json, iteration_duration)
        # VROOM only for the initial SplitClustering tree; batch repartitions keep the caller's solver.
        initial_split_json =
          if OptimizerWrapper.config[:services]&.key?(:vroom)
            repartition_default_json.merge(service: :vroom)
          else
            repartition_default_json
          end
        split_service_vrp = Models::ResolutionContext.new(initial_split_json)
        split_vrp = split_service_vrp.vrp

        split_resolution = split_vrp.configuration.resolution

        # Make sure vehicle_limit allows splitting on vehicles dimension.
        split_resolution.vehicle_limit ||= split_vrp.vehicles.size

        # Apply per-iteration budget to the initial SplitClustering attempt.
        if iteration_duration && (split_resolution.duration.nil? || split_resolution.duration > iteration_duration)
          split_resolution.duration = iteration_duration
        end

        Interpreters::SplitClustering.split_clusters(split_service_vrp, job, &block)
      end

      # Detect impossible overlaps after merging sub-solutions (same service over-assigned, same vehicle twice, etc.).
      def validate_repartition_solution_no_duplicates!(solution, vrp, context_message)
        return if solution.nil? || !solution.is_a?(Models::Solution)

        mission_keys = []
        solution.routes.each do |route|
          route.stops.each do |stop|
            next if stop.is_a?(Models::Solution::StopDepot)

            # One logical mission per stop (pickup/delivery vs plain service).
            if stop.pickup_shipment_id
              mission_keys << [:pickup, stop.pickup_shipment_id]
            elsif stop.delivery_shipment_id
              mission_keys << [:delivery, stop.delivery_shipment_id]
            elsif stop.service_id
              mission_keys << [:service, stop.service_id]
            end
          end
        end

        counts = mission_keys.tally
        service_by_id = vrp.services.each_with_object({}){ |s, h| h[s.id] = s }

        counts.each do |(kind, id), cnt|
          case kind
          when :service
            svc = service_by_id[id]
            max_visits = svc ? [svc.visits_number.to_i, 1].max : 1
            next if cnt <= max_visits

            raise DuplicateAssignmentError.new(
              "#{context_message}: service #{id.inspect} appears #{cnt} times on routes (max #{max_visits})"
            )
          when :pickup, :delivery
            next if cnt <= 1

            raise DuplicateAssignmentError.new(
              "#{context_message}: #{kind} shipment #{id.inspect} appears #{cnt} times on routes"
            )
          end
        end

        assigned_service_ids =
          counts.select{ |(k, _), c| k == :service && c.positive? }.keys.map{ |(_, sid)| sid }.to_set
        solution.unassigned_stops.each do |stop|
          sid = stop.service_id
          next if sid.nil?

          next unless assigned_service_ids.include?(sid)

          raise DuplicateAssignmentError.new(
            "#{context_message}: service #{sid.inspect} is both assigned on a route and listed as unassigned"
          )
        end

        vehicle_route_counts = Hash.new(0)
        solution.routes.each do |route|
          has_mission_stop =
            route.stops.any? do |stop|
              if stop.is_a?(Models::Solution::StopDepot)
                false
              else
                stop.service_id || stop.pickup_shipment_id || stop.delivery_shipment_id
              end
            end
          next unless has_mission_stop

          vehicle_route_counts[route.vehicle_id] += 1
        end

        vehicle_route_counts.each do |vid, n|
          next if n <= 1

          raise DuplicateAssignmentError.new(
            "#{context_message}: vehicle #{vid.inspect} has #{n} routes carrying missions (expected at most 1)"
          )
        end
      end

      def damped_neighbor_weight(raw_count)
        r = raw_count.to_f
        return 0.0 unless r.positive?

        r**NEIGHBOR_WEIGHT_POWER
      end

      # Per-iteration RNG so batching varies between repartition rounds but stays reproducible
      # when resolution.random_seed is set.
      def clustering_rng(vrp, iteration_index)
        seed = vrp.configuration.resolution&.random_seed
        return Random.new if seed.nil?

        Random.new(seed.to_i + iteration_index)
      end

      def build_default_service_vrp_json(service_vrp)
        raw = service_vrp.as_json
        sanitize_repartition_vrp_json!(raw[:vrp]) if raw[:vrp]

        raw.merge(split_solve_data: {})
      end

      # In-place fixes for safe Vrp.create after JSON round-trip.
      def sanitize_repartition_vrp_json!(vrp_json)
        return unless vrp_json

        # Sub-problems compute their own routing matrices; stale matrix_index
        # without matrices triggers DiscordantProblemError.
        vrp_json[:points]&.each { |p| p.delete(:matrix_index) }

        vrp_json[:relations]&.each do |r|
          r[:linked_service_ids] ||= []
          r[:linked_vehicle_ids] ||= []
        end

        vrp_json[:matrices] ||= []
        vrp_json[:vehicles]&.each { |v| v.delete(:matrix_id) if vrp_json[:matrices].empty? }
      end

      def candidate?(service_vrp)
        vrp = service_vrp.vrp
        resolution = vrp.configuration.resolution

        vehicle_limit = resolution.dicho_algorithm_vehicle_limit.to_i
        service_limit = resolution.dicho_algorithm_service_limit

        return false if service_vrp.service == :vroom
        return false if vehicle_limit <= 0 || service_limit <= 0
        return false if service_limit.nil? || vrp.services.size <= service_limit && vrp.vehicles.size <= vehicle_limit
        return false if vrp.schedule?
        return false if vrp.points.empty?
        return false if vrp.points.any?{ |p| p.location.nil? }

        true
      end

      def build_graph(vrp)
        VrpGraph::GraphBuilder.new(vrp).build_per_skill
      end

      # Greedy probabilistic grouping of routes into batches using
      # service-level graph neighborhood. Each step picks the next route
      # via weighted random selection (probability proportional to shared
      # neighbor count with the current group).
      def cluster_vehicles_for_solution(solution, graph, rng: Random::DEFAULT)
        vehicle_ids = solution.routes.map(&:vehicle_id).compact.uniq
        return {} if vehicle_ids.empty?

        target_size = rand(10..15)
        k = (vehicle_ids.size / target_size.to_f).ceil
        return {} if k < 2

        route_services = {}
        solution.routes.each do |route|
          vid = route.vehicle_id
          next unless vid

          sids = {}
          route.stops.each do |stop|
            sid = stop.service_id
            sids[sid] = true if sid
          end
          route_services[vid] = sids
        end

        # Build route-to-route compatibility: number of shared graph neighbors.
        service_to_vehicle = {}
        route_services.each do |vid, sids|
          sids.each_key { |sid| service_to_vehicle[sid] ||= vid }
        end

        compatibility = Hash.new(0)
        route_services.each do |vid_a, sids_a|
          sids_a.each_key do |sid|
            graph.neighbors_for_service(sid).each do |nb_sid|
              vid_b = service_to_vehicle[nb_sid]
              next unless vid_b
              next if vid_a == vid_b

              key = vid_a.to_s < vid_b.to_s ? "#{vid_a}|#{vid_b}" : "#{vid_b}|#{vid_a}"
              compatibility[key] += 1
            end
          end
        end

        log "RePartition greedy clustering: vehicles=#{vehicle_ids.size} target_size=#{target_size} " \
            "k=#{k} compatibility_pairs=#{compatibility.size}",
            level: :info

        remaining = vehicle_ids.map(&:to_s).to_a
        vehicle_to_cluster = {}
        cluster_idx = 0

        while remaining.any?
          # Pick seed: weighted random among remaining, weight = total
          # compatibility with other remaining routes.
          seed_scores =
            remaining.map { |vid|
              score =
                remaining.sum { |other|
                  next 0 if vid == other

                  k2 = vid < other ? "#{vid}|#{other}" : "#{other}|#{vid}"
                  compatibility[k2]
                }
              [vid, damped_neighbor_weight(score)]
            }

          seed = weighted_random_pick(seed_scores, rng: rng)
          remaining.delete(seed)
          group = [seed]
          vehicle_to_cluster[seed] = cluster_idx

          while group.size < target_size && remaining.any?
            candidates =
              remaining.map { |vid|
                score =
                  group.sum { |gv|
                    k2 = vid < gv ? "#{vid}|#{gv}" : "#{gv}|#{vid}"
                    compatibility[k2]
                  }
                [vid, damped_neighbor_weight(score)]
              }

            pick = weighted_random_pick(candidates, rng: rng)
            break unless pick

            remaining.delete(pick)
            group << pick
            vehicle_to_cluster[pick] = cluster_idx
          end

          cluster_idx += 1
        end

        log "RePartition greedy result: #{vehicle_to_cluster.values.tally}", level: :info

        vehicle_to_cluster
      end

      def weighted_random_pick(candidates_with_scores, rng: Random::DEFAULT)
        return nil if candidates_with_scores.empty?

        total = candidates_with_scores.sum { |_, s| s }
        return candidates_with_scores.sample(random: rng)&.first if total <= 0

        r = rng.rand * total
        cumulative = 0.0
        candidates_with_scores.each do |candidate, score|
          cumulative += score
          return candidate if r <= cumulative
        end
        candidates_with_scores.last&.first
      end

      def repartition_once(
        repartition_context_payload, graph, solution, job = nil, iteration_duration = nil,
        iteration_index: 0, &block
      )
        ref_context = Models::ResolutionContext.new(repartition_context_payload)
        vrp = ref_context.vrp
        rng = clustering_rng(vrp, iteration_index)
        vehicle_to_cluster = cluster_vehicles_for_solution(solution, graph, rng: rng)

        batches = Hash.new{ |h, k| h[k] = [] }
        solution.routes.each_with_index do |route, idx|
          vid = route.vehicle_id
          batch_index = vehicle_to_cluster[vid.to_s] || 0
          batches[batch_index] << [idx, route]
        end

        log "RePartition batches: #{batches.transform_values{ |routes| routes.map{ |_idx, r| r.vehicle_id }.uniq }}",
            level: :info

        return nil if batches.empty?

        all_vehicle_ids = vrp.vehicles.map(&:id)

        vehicles_by_batch = {}
        batches.each do |batch_index, routes|
          vehicles_by_batch[batch_index] = routes.map{ |_idx, route| route.vehicle.id }.uniq
        end

        used_vehicle_ids = vehicles_by_batch.values.flatten.uniq
        unused_vehicle_ids = all_vehicle_ids - used_vehicle_ids

        vehicle_has_services = {}
        solution.routes.each do |route|
          vid = route.vehicle.id
          has_services = route.stops.any?(&:service_id)
          vehicle_has_services[vid] ||= has_services
        end

        initial_unassigned = solution.unassigned_stops.dup

        # Pre-compute service_ids per batch (for graph neighborhood scoring)
        batch_service_ids = {}
        batches.each do |batch_index, routes|
          sids =
            routes.flat_map{ |_idx, route|
              route.stops.filter_map(&:service_id)
            }.compact.uniq
          batch_service_ids[batch_index] = sids.each_with_object({}){ |sid, h| h[sid] = true }
        end

        # Associate unassigned services to the most compatible batch via
        # service-level graph neighborhood.
        extra_services_per_batch = Hash.new{ |h, k| h[k] = Hash.new(true) }
        assigned_service_ids = {}

        initial_unassigned.each do |stop|
          service_id = stop.service_id
          next unless service_id
          next if assigned_service_ids.key?(service_id)

          neighbors = graph.neighbors_for_service(service_id)

          best_batch = nil
          best_score = -1

          batches.each_key do |batch_index|
            sid_hash = batch_service_ids[batch_index]
            score =
              if neighbors.empty? || sid_hash.empty?
                0
              else
                neighbors.count{ |sid| sid_hash[sid] }
              end

            if score > best_score
              best_score = score
              best_batch = batch_index
            end
          end

          if best_batch.nil?
            best_batch =
              batches.min_by{ |_idx, routes| routes.size }&.first
          end

          next if best_batch.nil?

          extra_services_per_batch[best_batch][service_id] = true
          assigned_service_ids[service_id] = true
        end

        sub_solutions = []

        batch_count = batches.size
        per_batch_duration =
          if iteration_duration && batch_count.positive?
            (iteration_duration.to_f / batch_count).floor
          end
        per_batch_duration = nil if per_batch_duration && per_batch_duration <= 0

        batches.each do |batch_index, routes|
          log "RePartition solving batch #{batch_index}/#{batches.size} with #{routes.size} routes", level: :info
          service_ids = routes.flat_map{ |_idx, route|
            route.stops.map(&:service_id)
          }.compact.uniq

          vehicle_ids = vehicles_by_batch[batch_index].dup

          desired_cluster_size = (10..15).to_a.sample
          if vehicle_ids.size < desired_cluster_size
            free_unused =
              unused_vehicle_ids.select{ |vid|
                vehicle_has_services[vid] == false || vehicle_has_services[vid].nil?
              }
            needed = desired_cluster_size - vehicle_ids.size
            extra = free_unused.first(needed)
            unless extra.empty?
              vehicle_ids.concat(extra)
              vehicle_ids.uniq!
              unused_vehicle_ids -= extra
            end
          end

          service_ids.concat(extra_services_per_batch[batch_index].keys)
          service_ids.uniq!

          next if service_ids.empty?

          vehicle_indices =
            vrp.vehicles.each_with_index.filter_map{ |vehicle, v_idx|
              v_idx if vehicle_ids.include?(vehicle.id)
            }

          next if vehicle_indices.empty?

          # Hot start: subset of all_vrp_routes for this sub-problem's vehicles.
          batch_vrp_routes = solution.vrp_routes(vehicle_ids)

          sub_service_vrp =
            Interpreters::SplitClustering.build_partial_service_vrp(
              Models::ResolutionContext.new(repartition_context_payload),
              service_ids,
              vehicle_indices
            )

          if batch_vrp_routes.any?
            sub_vrp = sub_service_vrp.vrp
            hot_routes = sub_vrp.routes_from_initial_specs(batch_vrp_routes)
            if hot_routes.any?
              hot_vehicle_ids = hot_routes.map(&:vehicle_id).each_with_object({}){ |vid, h| h[vid] = true }
              sub_vrp.routes =
                sub_vrp.routes.reject{ |r| hot_vehicle_ids[r.vehicle_id] } + hot_routes
            end
          end

          sub_service_vrp.split_solve_data =
            (sub_service_vrp.split_solve_data || {}).merge(cannot_split_further: true)

          sub_resolution = sub_service_vrp.vrp.configuration.resolution

          # Prevent recursive re-entry into RePartition for sub-problems.
          sub_resolution.dicho_algorithm_vehicle_limit = 0
          sub_resolution.dicho_algorithm_service_limit = 0

          if per_batch_duration && (sub_resolution.duration.nil? || sub_resolution.duration > per_batch_duration)
            sub_resolution.duration = per_batch_duration
          end

          log "RePartition solving sub-problem with #{sub_service_vrp.vrp.services.size} services \
              and #{sub_service_vrp.vrp.vehicles.size} vehicles", level: :info
          sub_solution = Core::Strategies::Orchestration.solve(sub_service_vrp, job, block)
          next unless sub_solution

          sub_solutions << sub_solution
        end

        return nil if sub_solutions.empty?

        combined = sub_solutions.reduce(&:+)

        leftover_unassigned =
          initial_unassigned.reject{ |stop| assigned_service_ids.key?(stop.service_id) }
        combined.unassigned_stops.concat(leftover_unassigned)

        validate_repartition_solution_no_duplicates!(combined, vrp, "RePartition iteration batch merge")

        combined
      end

      def score_solution(solution, vrp)
        unassigned = solution&.unassigned_stops&.size || vrp.services.size
        cost =
          if solution.respond_to?(:cost) && !solution.cost.nil?
            solution.cost.to_f
          else
            Float::INFINITY
          end
        [unassigned, cost]
      end

      def better_score?(lhs, rhs)
        return true if lhs[0] < rhs[0]
        return false if lhs[0] > rhs[0]

        lhs[1] < rhs[1]
      end
    end
  end
end
