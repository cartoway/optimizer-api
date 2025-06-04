module Core
  module Components
    module Zone
      def apply_zones(vrp)
        vrp.zones.each{ |zone|
          next if zone.allocations.empty?

          zone.vehicles =
            if zone.allocations.size == 1
              zone.allocations[0].collect{ |vehicle_id| vrp.vehicles.find{ |vehicle| vehicle.id == vehicle_id } }.compact
            else
              zone.allocations.collect{ |alloc| vrp.vehicles.find{ |vehicle| vehicle.id == alloc.first } }.compact
            end

          next if zone.vehicles.compact.empty?

          zone.vehicles.each{ |vehicle|
            vehicle.skills.each{ |skillset| skillset << zone[:id].to_sym }
          }
        }

        return unless vrp.points.all?(&:location)

        vrp.zones.each{ |zone|
          related_ids = vrp.services.collect{ |service|
            activity_loc = service.activity.point.location

            next unless zone.inside(activity_loc.lat, activity_loc.lon)

            service.skills += [zone[:id].to_sym]
            service.id
          }.compact

          # Remove zone allocation verification if we need to assign zone without vehicle affectation together
          next unless zone.allocations.size > 1 && related_ids.size > 1

          vrp.relations += [{
            type: :same_route,
            linked_ids: related_ids.flatten,
          }]
        }
      end
      module_function :apply_zones
    end
  end
end
