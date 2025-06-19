module Core
  module Strategies
    module Orchestration
      def define_main_process(services_vrps, job = nil, &block)
        log "--> define_main_process #{services_vrps.size} VRPs"
        log "activities: #{services_vrps.map{ |sv| sv.vrp.services.size }}"
        log "vehicles: #{services_vrps.map{ |sv| sv.vrp.vehicles.size }}"
        log 'configuration.resolution.vehicle_limit: '\
            "#{services_vrps.map{ |sv| sv.vrp.configuration.resolution.vehicle_limit }}"
        log "min_durations: #{services_vrps.map{ |sv| sv.vrp.configuration.resolution.minimum_duration&.round }}"
        log "max_durations: #{services_vrps.map{ |sv| sv.vrp.configuration.resolution.duration&.round }}"
        tic = Time.now

        expected_activity_count = services_vrps.collect{ |sv| sv.vrp.visits }.sum

        several_service_vrps = Interpreters::SeveralSolutions.expand_similar_resolutions(services_vrps)
        several_solutions =
          several_service_vrps.collect.with_index{ |current_service_vrps, solution_index|
            callback_main =
              lambda { |wrapper, avancement, total, message, cost = nil, time = nil, solution = nil|
                add = "solution #{solution_index + 1}/#{several_service_vrps.size}"
                msg = several_service_vrps.size > 1 && concat_avancement(add, message) || message
                block&.call(wrapper, avancement, total, msg, cost, time, solution)
              }

            join_independent_vrps(current_service_vrps, callback_main) { |service_vrp, callback_join|
              repeated_results = []

              service_vrp_repeats = Interpreters::SeveralSolutions.expand_repetitions(service_vrp)

              service_vrp_repeats.each_with_index{ |repeated_service_vrp, repetition_index|
                repeated_results <<
                  define_process(repeated_service_vrp, job) { |wrapper, avancement, total, message, cost, time, solution|
                    add = "repetition #{repetition_index + 1}/#{service_vrp_repeats.size}"
                    msg = service_vrp_repeats.size > 1 && concat_avancement(add, message) || message
                    callback_join&.call(wrapper, avancement, total, msg, cost, time, solution)
                  }
                Models.delete_all # needed to prevent duplicate ids because expand_repeat uses Marshal.load/dump

                break if repeated_results.last.unassigned_stops.empty? # No need to repeat more, cannot do better than this
              }

              # NOTE: the only criteria is number of unassigneds at the moment so if there is ever a solution with zero
              # unassigned, the loop is cut early. That is, if the criteria below is evolved, the above `break if`
              # condition should be modified in a similar fashion)
              # find the best result and its index
              (result, position) =
                repeated_results.each.with_index(1).min_by { |rresult, _| rresult.unassigned_stops.size }
              log "#{job}_repetition - #{repeated_results.collect{ |r| r.unassigned_stops.size }} : "\
                  "chose to keep the #{position.ordinalize} solution"
              result
            }
          }

        # demo solver returns a fixed solution
        unless services_vrps.collect(&:service).uniq == [:demo]
          Core::Components::Solution.check_solutions_consistency(expected_activity_count, several_solutions)
        end

        nb_routes = several_solutions.sum(&:count_used_routes)
        nb_unassigned = several_solutions.sum(&:count_unassigned_services)
        percent_unassigned = (100.0 * nb_unassigned / expected_activity_count).round(1)

        log "result - #{nb_unassigned} of #{expected_activity_count} (#{percent_unassigned}%) unassigned activities"
        log "result - #{nb_routes} of #{services_vrps.sum{ |sv| sv.vrp.vehicles.size }} vehicles used"

        several_solutions
      ensure
        log "<-- define_main_process elapsed: #{(Time.now - tic).round(2)} sec"
      end

      # Mutually recursive method
      def define_process(service_vrp, job = nil, &block)
        vrp = service_vrp.vrp
        dicho_level = service_vrp.dicho_level.to_i
        split_level = service_vrp.split_level.to_i
        shipment_size = vrp.relations.count{ |r| r.type == :shipment }

        # Repopulate Objects which are referenced by others using ids but deleted by the multiple sub problem creations
        vrp.units.each{ |unit| Models::Unit.insert(unit) } if Models::Unit.all.empty?
        vrp.points.each{ |point| Models::Point.insert(point) } if Models::Point.all.empty?
        vrp.services.each{ |s| Models::Service.insert(s) } if Models::Service.all.empty?

        log "--> define_process VRP (service: #{vrp.services.size} including #{shipment_size} shipment relations, "\
            "vehicle: #{vrp.vehicles.size}, v_limit: #{vrp.configuration.resolution.vehicle_limit}) "\
            "with levels (dicho: #{dicho_level}, split: #{split_level})"
        log "min_duration #{vrp.configuration.resolution.minimum_duration&.round} "\
            "max_duration #{vrp.configuration.resolution.duration&.round}"

        tic = Time.now
        expected_activity_count = vrp.visits

        # Calls define_process recursively
        solution ||= Interpreters::SplitClustering.split_clusters(service_vrp, job, &block)
        # Calls define_process recursively
        solution ||= Interpreters::Dichotomous.dichotomous_heuristic(service_vrp, job, &block)

        solution ||= solve(service_vrp, job, block)

        Cleanse.cleanse(vrp, solution)
        if service_vrp.service != :demo # demo solver returns a fixed solution
          Core::Components::Solution.check_solutions_consistency(expected_activity_count, [solution])
        end
        log "<-- define_process levels (dicho: #{dicho_level}, split: #{split_level}) "\
            "elapsed: #{(Time.now - tic).round(2)} sec"
        solution.configuration.deprecated_headers = vrp.configuration.restitution.use_deprecated_csv_headers
        solution
      end

      def solve(service_vrp, job = nil, block = nil)
        vrp = service_vrp.vrp
        service = service_vrp.service
        optim_wrapper_config = OptimizerWrapper.config[:services][service]
        dicho_level = service_vrp.dicho_level
        shipment_size = vrp.relations.count{ |r| r.type == :shipment }
        log "--> optim_wrap::solve VRP (service: #{vrp.services.size} including #{shipment_size} shipment relations, " \
            "vehicle: #{vrp.vehicles.size} v_limit: #{vrp.configuration.resolution.vehicle_limit}) with levels " \
            "(dicho: #{service_vrp.dicho_level}, split: #{service_vrp.split_level.to_i})", level: :debug

        tic = Time.now

        optim_solution = nil

        unfeasible_services = {}

        if !vrp.subtours.empty?
          multi_modal = Interpreters::MultiModal.new(vrp, service)
          optim_solution = multi_modal.multimodal_routes
        elsif vrp.vehicles.empty? || vrp.services.empty?
          unassigned_with_reason =
            vrp.services.map{ |s|
              Models::Solution::Stop.new(s, reason: 'No vehicle available for this service')
            }
          optim_solution = vrp.empty_solution(service.to_s, unassigned_with_reason, false)
        else
          unfeasible_services = optim_wrapper_config.detect_unfeasible_services(vrp)

          # if all services are unfeasible just return an empty solution
          if vrp.services.size == unfeasible_services.size
            optim_solution = Models::Solution.new(
              solvers: [service.to_s],
              routes: vrp.vehicles.map{ |v| vrp.empty_route(v) },
              unassigned_stops: []
            )
          else
            # TODO: Eliminate the points which has no feasible vehicle or service
            vrp.compute_matrix(job, &block)

            optim_wrapper_config.check_distances(vrp, unfeasible_services)

            # TODO: Eliminate the vehicles which cannot serve any
            # service vrp.services.all?{ |s| s.vehicle_compatibility[v.id] == false }

            # Remove infeasible services
            services_to_reinject = []
            unfeasible_services.each_key{ |una_service_id|
              index = vrp.services.find_index{ |s| s.id == una_service_id }
              if index
                services_to_reinject << vrp.services.slice!(index)
              end
            }

            # vrp.periodic_heuristic check the first_solution_stategy which may change right after periodic heuristic
            periodic_heuristic_flag = vrp.periodic_heuristic?
            # TODO: refactor with dedicated class
            if vrp.schedule?
              periodic = Interpreters::PeriodicVisits.new(vrp)
              vrp = periodic.expand(vrp, job, &block)
              if vrp.periodic_heuristic?
                optim_solution = vrp.configuration.preprocessing.heuristic_result
                if vrp.configuration.resolution.solver
                  first_solution_strategy = vrp.configuration.preprocessing.first_solution_strategy
                  first_solution_strategy.delete('periodic')
                  first_solution_strategy << 'global_cheapest_arc' if first_solution_strategy.empty?
                end
              end
            end
            if vrp.configuration.resolution.solver && (!periodic_heuristic_flag || vrp.services.size < 200)
              if vrp.configuration.preprocessing.cluster_threshold.to_f.positive?
                block&.call(nil, nil, nil,
                            'process clique clustering : threshold '\
                            "(#{vrp.configuration.preprocessing.cluster_threshold.to_f}) ",
                            nil, nil, nil)
              end
              optim_solution =
                Core::Services::ClusteringService.clique_cluster(
                  vrp,
                  vrp.configuration.preprocessing.cluster_threshold
                ) { |cliqued_vrp|
                  time_start = Time.now

                  optim_wrapper_config.simplify_constraints(cliqued_vrp)

                  block&.call(nil, 0, nil, 'run optimization', nil, nil, nil) if dicho_level.nil? || dicho_level.zero?

                  # TODO: Move select best heuristic in each solver
                  Interpreters::SeveralSolutions.custom_heuristics(service, vrp, block)

                  cliqued_solution =
                    optim_wrapper_config.solve(
                      cliqued_vrp,
                      job,
                      proc{ |pids|
                        next unless job

                        result_object = OptimizerWrapper::Result.get(job) || { pids: [] }
                        result_object[:pids] = pids
                        OptimizerWrapper::Result.set(job, result_object)
                      }
                    ) { |wrapper, avancement, total, _message, cost, _time, solution|
                      solution =
                        if solution.is_a?(Models::Solution)
                          optim_wrapper_config.patch_simplified_constraints_in_solution(solution, cliqued_vrp)
                        end
                      if dicho_level.nil? || dicho_level.zero?
                        block&.call(wrapper, avancement, total,
                                    'run optimization, iterations', cost, (Time.now - time_start) * 1000, solution)
                      end
                      solution
                    }
                  optim_wrapper_config.patch_and_rewind_simplified_constraints(cliqued_vrp, cliqued_solution)

                  if cliqued_solution.is_a?(Models::Solution)
                    block&.call(nil, nil, nil, 'run optimization', nil, nil, nil) if dicho_level&.positive?
                    cliqued_solution
                  elsif cliqued_solution.status == :killed
                    next
                  elsif cliqued_solution.is_a?(String)
                    raise cliqued_solution
                  elsif (vrp.configuration.preprocessing.heuristic_result.nil? ||
                          vrp.configuration.preprocessing.heuristic_result.empty?) &&
                        !vrp.configuration.restitution.allow_empty_result
                    puts cliqued_solution
                    raise 'No solution provided'
                  end
                }
            end
            # Reintegrate unfeasible services deleted from vrp.services to help ortools
            vrp.services += services_to_reinject
          end
        end
        if optim_solution # Job might have been killed
          if periodic_heuristic_flag
            periodic_solution = vrp.configuration.preprocessing.heuristic_result

            # TODO: uniformize cost computation to define a comparison operator between solutions
            if periodic_solution.unassigned_stops.size < optim_solution.unassigned_stops.size
              optim_solution = periodic_solution
            end
          end
          optim_solution.name = vrp.name
          optim_solution.configuration.csv = vrp.configuration.restitution.csv
          optim_solution.configuration.geometry = vrp.configuration.restitution.geometry
          optim_solution.unassigned_stops += unfeasible_services.values.flatten
          Cleanse.cleanse(vrp, optim_solution)
          optim_solution.parse(vrp)
          if vrp.configuration.preprocessing.first_solution_strategy
            optim_solution.heuristic_synthesis = vrp.configuration.preprocessing.heuristic_synthesis
          end
        else
          optim_solution = vrp.empty_solution(service, unfeasible_services.values)
        end

        log "<-- optim_wrap::solve elapsed: #{(Time.now - tic).round(2)}sec", level: :debug
        optim_solution
      end

      def build_independent_vrps(vrp, skill_sets, vehicle_indices_by_skills, skill_service_ids)
        unused_vehicle_indices = (0..vrp.vehicles.size - 1).to_a
        independent_vrps =
          skill_sets.collect{ |skills_set|
            # Compatible problem ids are retrieved
            vehicle_indices = skills_set.flat_map{ |skills|
              vehicle_indices_by_skills.select{ |k, _v| (skills - k).empty? }.flat_map{ |_k, v| v }
            }.uniq
            vehicle_indices.each{ |index| unused_vehicle_indices.delete(index) }
            service_ids = skills_set.flat_map{ |skills| skill_service_ids[skills] }

            service_vrp = Models::ResolutionContext.new(service: nil, vrp: vrp)
            Interpreters::SplitClustering.build_partial_service_vrp(service_vrp,
                                                                    service_ids,
                                                                    vehicle_indices).vrp
          }
        is_sticky = vrp.services.all?{ |service| service.skills.any?{ |skill| skill.to_s.include?("sticky_skill") } }
        total_size =
          is_sticky ? vrp.vehicles.size :
            independent_vrps.collect{ |s_vrp| s_vrp.services.size * [1, s_vrp.vehicles.size].min }.sum
        independent_vrps.each{ |sub_vrp|
          # If one sub vrp has no vehicle or no service, duration can be zero.
          # We only split duration among sub_service_vrps that have at least one vehicle and one service.
          this_sub_size =
            is_sticky ? sub_vrp.vehicles.size :
              sub_vrp.services.size * [1, sub_vrp.vehicles.size].min
          Interpreters::SplitClustering.adjust_independent_duration(sub_vrp, this_sub_size, total_size)
        }

        return independent_vrps if unused_vehicle_indices.empty?

        sub_service_vrp =
          Interpreters::SplitClustering.build_partial_service_vrp(
            Models::ResolutionContext.new(service: nil, vrp: vrp),
            [],
            unused_vehicle_indices
          )
        independent_vrps.push(sub_service_vrp.vrp)

        independent_vrps
      end

      # Split the VRP into independent subproblems based on skills and relations
      def split_independent_vrp(vrp)
        # Don't split vrp if
        # - No vehicle
        # - No service
        # - there is multimodal subtours
        return [vrp] if (vrp.vehicles.size <= 1) || vrp.services.empty? || vrp.subtours&.any?

        # - there is a service with no skills (or sticky vehicle)
        mission_skills = vrp.services.map(&:skills).uniq
        return [vrp] if mission_skills.include?([])

        if vrp.relations.any?{ |r| Models::Relation::FORCING_RELATIONS.include?(r.type) }
          log 'split_independent_vrp does not support vehicle_trips and other FORCING_RELATIONS yet', level: :warn
          return [vrp]
        end

        # Generate Services data
        grouped_services = vrp.services.group_by(&:skills)
        skill_service_ids = Hash.new{ [] }
        grouped_services.each{ |skills, missions| skill_service_ids[skills] += missions.map(&:id) }

        # Generate Vehicles data
        if vrp.vehicles.any?{ |v| v.skills.size > 1 } # alternative skills
          log 'split_independent_vrp does not support alternative set of vehicle skills', level: :warn
          return [vrp]
        end
        grouped_vehicles = vrp.vehicles.group_by{ |vehicle| vehicle.skills.flatten }
        vehicle_skills = grouped_vehicles.keys.uniq
        vehicle_indices_by_skills = Hash.new{ [] }
        grouped_vehicles.each{ |skills, vehicles|
          vehicle_indices_by_skills[skills] += vehicles.map{ |vehicle| vrp.vehicles.find_index(vehicle) }
        }

        independent_skill_sets = Core::Components::Vrp.compute_independent_skills_sets(vrp, mission_skills, vehicle_skills)

        build_independent_vrps(vrp, independent_skill_sets, vehicle_indices_by_skills, skill_service_ids)
      end

      # Join the solutions of independent VRPs
      def join_independent_vrps(services_vrps, callback)
        solutions =
          services_vrps.each_with_index.map{ |service_vrp, i|
            block =
              if services_vrps.size > 1 && !callback.nil?
                proc { |wrapper, avancement, total, message, cost = nil, time = nil, solution = nil|
                  add = "split independent process #{i + 1}/#{services_vrps.size}"
                  msg = concat_avancement(add, message) || message
                  callback&.call(wrapper, avancement, total, msg, cost, time, solution)
                }
              else
                callback
              end
            yield(service_vrp, block)
          }

        solutions.reduce(&:+)
      end

      # Concatenate progress messages
      def concat_avancement(addition, message)
        return unless message

        "#{addition} - #{message}"
      end
      module_function :define_main_process,
                      :define_process,
                      :solve,
                      :build_independent_vrps,
                      :split_independent_vrp,
                      :join_independent_vrps,
                      :concat_avancement
    end
  end
end
