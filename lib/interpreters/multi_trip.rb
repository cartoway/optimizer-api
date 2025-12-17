module Interpreters
  class MultiTrip
    # Class-level presolve entry point used by orchestration
    # Delegates to the instance-level implementation to keep logic in one place.
    def self.presolve(service_vrp, job = nil, &block)
      new.presolve(service_vrp, job, &block)
    end

    def presolvable?(service_vrp)
      service_vrp[:service] == :pyvrp && service_vrp[:skipped_services].any?{ |skipped_service|
        skipped_service[:service] == :vroom &&
          skipped_service[:reasons].all?{ |reason| reason == :assert_vehicles_no_reload_depots }
      }
    end

    def resolvable?(solution)
      solution.routes.any?(&:under_used?)
    end

    def presolve(service_vrp, job = nil, &block)
      if presolvable?(service_vrp)
        service_vrp.vrp.configuration.resolution.solver = :vroom
        service_vrp[:service] = :vroom

        solution = Core::Strategies::Orchestration.solve(service_vrp, job, &block)

        # extract routes below 80% of work_time of the vehicle to build a new service_vrp
        if resolvable?(solution)
          under_used_routes = solution.routes.select(&:under_used?)
          log "Under used routes: #{under_used_routes.size}"
          solution.routes -= under_used_routes
          sub_service_ids =
            under_used_routes.map{ |route| route.stops.map(&:service_id) }.flatten +
            solution.unassigned_stops.map(&:service_id)
          sub_services =
            service_vrp.vrp.services.select{ |service| sub_service_ids.include?(service.id) }
          solution.unassigned_stops = []

          vehicles = under_used_routes.map(&:vehicle)
          reload_depots = vehicles.flat_map(&:reload_depots)
          points =
            vehicles.map(&:start_point) +
            vehicles.map(&:end_point) +
            reload_depots.map(&:point) +
            sub_services.map{ |service| service.activity.point }
          sub_vrp_hash = {
            points: points.uniq.map(&:as_json),
            vehicles: vehicles.map(&:as_json),
            services: sub_services.map(&:as_json),
            # relations: [], # PyVRP does not hand relations
            units: service_vrp.vrp.units.map(&:as_json),
            reload_depots: reload_depots.map(&:as_json),
            configuration: service_vrp.vrp.configuration.as_json
          }
          sub_vrp_hash[:vehicles].each{ |vehicle| vehicle.delete(:matrix_id) }
          sub_vrp_hash[:points].each{ |point| point.delete(:matrix_index) }
          sub_vrp_hash[:configuration][:resolution][:duration] -= solution.elapsed
          new_service_vrp =
            Models::ResolutionContext.new(service: :pyvrp, vrp: Models::Vrp.create(sub_vrp_hash, check: false))
          sub_solution = Core::Strategies::Orchestration.solve(new_service_vrp, job, &block)
          solution.routes += sub_solution.routes
          solution.unassigned_stops = sub_solution.unassigned_stops
        end
        solution
      end
    end
  end
end
