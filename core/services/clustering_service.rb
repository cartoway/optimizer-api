module Core
  module Services
    module ClusteringService
      RELATION_ZIP_CLUSTER_CAN_HANDLE = %i[
        maximum_day_lapse
        maximum_duration_lapse
        minimum_day_lapse
        minimum_duration_lapse
        vehicle_group_duration
        vehicle_group_duration_on_months
        vehicle_group_duration_on_weeks
        vehicle_group_number
        vehicle_trips
      ].freeze

      def clique_cluster_candidate?(vrp, cluster_threshold)
        cluster_threshold && vrp.matrices.any? && vrp.services.all?(&:activity) && vrp.rests.empty? &&
          !vrp.schedule? && (vrp.relations.map(&:type) - RELATION_ZIP_CLUSTER_CAN_HANDLE).empty? &&
          vrp.services.none?{ |s| s.activity.timewindows.any? }
      end

      def clique_cluster(vrp, cluster_threshold)
        zip_condition = clique_cluster_candidate?(vrp, cluster_threshold)

        if zip_condition
          if vrp.services.any?{ |s| s.activities.any? }
            raise UnsupportedProblemError('Threshold is not supported yet if one service has serveral activies.')
          end

          original_services = Array.new(vrp.services.size){ |i| vrp.services[i].clone }
          clusters = zip_cluster(vrp, cluster_threshold)
        end
        solution = yield(vrp)

        if zip_condition
          vrp.services = original_services
          unzip_cluster(solution, clusters, vrp)
        else
          solution
        end
      end

      def zip_cluster(vrp, cluster_threshold)
        return nil if vrp.services.empty?

        c = Ai4r::Clusterers::CompleteLinkageMaxDistance.new

        matrix = vrp.matrices[0][vrp.vehicles[0].router_dimension.to_sym]
        used_units = {}
        vrp.services.each{ |s| s.quantities.each{ |q| used_units[q.unit.id] = true if q.value != 0 } }
        no_useful_capacities =
          vrp.vehicles.none?{ |v|
            v.capacities.any?{ |capa| capa.limit && used_units.key?(capa.unit.id) }
          }

        c.distance_function =
          lambda do |a, b|
            aa = vrp.services[a[0]]
            bb = vrp.services[b[0]]
            (no_useful_capacities || (aa.quantities&.empty? && bb.quantities&.empty?)) && aa.skills == bb.skills ?
            matrix[aa.activity.point.matrix_index][bb.activity.point.matrix_index] : Float::INFINITY
          end

        data_set = Ai4r::Data::DataSet.new(data_items: (0..(vrp.services.length - 1)).collect{ |i| [i] })

        clusterer = c.build(data_set, cluster_threshold)

        new_size = clusterer.clusters.size

        # Build replacement list
        new_services = Array.new(new_size)
        clusterer.clusters.each_with_index do |cluster, i|
          new_services[i] = vrp.services[cluster.data_items[0][0]]
          cluster_ids = cluster.data_items.map{ |arr| vrp.services[arr[0]].id }
          route_index = vrp.routes.index{ |route| route.mission_ids & cluster_ids }
          if route_index
            ref_id =
              vrp.routes[route_index].mission_ids.find{ |mission_id|
                cluster_ids.include?(mission_id)
              }
            vrp.routes.each{ |route|
              route.mission_ids.delete_if{ |mission_id|
                cluster_ids.include?(mission_id) unless mission_id == ref_id
              }
            }
            vrp.routes[route_index].mission_ids.map!{ |mission_id|
              if cluster_ids.include?(mission_id)
                new_services[i].id
              else
                mission_id
              end
            }
          end

          new_services[i].activity.duration =
            cluster.data_items.map{ |di| vrp.services[di[0]].activity.duration }.reduce(&:+)
          new_services[i].priority = cluster.data_items.map{ |di| vrp.services[di[0]].priority }.min
        end

        # Fill new vrp
        vrp.services = new_services

        clusterer.clusters
      end

      def unzip_cluster(solution, clusters, original_vrp)
        return solution unless clusters

        new_routes =
          solution.routes.map{ |route|
            previous_stop = nil
            new_stops =
              route.stops.flat_map.with_index{ |stop, act_index|
                if stop.service_id
                  service_index = original_vrp.services.index{ |s| s.id == stop.service_id }
                  cluster_index = clusters.index{ |z| z.data_items.flatten.include? service_index }
                  if cluster_index && clusters[cluster_index].data_items.size > 1
                    cluster_data_indices = clusters[cluster_index].data_items.collect{ |i| i[0] }
                    cluster_services = cluster_data_indices.map{ |index| original_vrp.services[index] }
                    next_stop = route.stops[act_index + 1..route.stops.size].find{ |act| act.activity.point }
                    tsp = TSPHelper.create_tsp(original_vrp,
                                               vehicle: route.vehicle,
                                               services: cluster_services,
                                               start_point: previous_stop&.activity&.point,
                                               end_point: next_stop&.activity&.point,
                                               begin_time: previous_stop&.info&.end_time)
                    tsp_solution = TSPHelper.solve(tsp)
                    previous_stop = tsp_solution.routes[0].stops.reverse.find(&:service_id)
                    service_stops = tsp_solution.routes[0].stops.select{ |a| a.type == :service }
                    service_stops.map!{ |service_stop|
                      original_service = original_vrp.services.find{ |service| service.id == service_stop.id }
                      stop = Models::Solution::Stop.new(original_service, info: service_stop.info)
                    }
                    shift = tsp_solution.routes[0].info.total_travel_time - stop.info.travel_time -
                            (next_stop&.info&.travel_time || 0)
                    route.shift_route_times(shift, act_index + 1) if act_index < route.stops.size
                    service_stops
                  else
                    stop
                  end
                else
                  previous_stop = stop.activity.point ? stop : previous_stop
                  stop
                end
              }
            Models::Solution::Route.new(stops: new_stops, vehicle: route.vehicle)
          }
        new_unassigned =
          solution.unassigned_stops.flat_map{ |un|
            if un.service_id
              service_index = original_vrp.services.index{ |s| s.id == un.service_id }
              cluster_index = clusters.index{ |z| z.data_items.flatten.include? service_index }
              if cluster_index && clusters[cluster_index].data_items.size > 1
                cluster_data_indices = clusters[cluster_index].data_items.collect{ |i| i[0] }
                cluster_data_indices.map{ |index|
                  Models::Solution::Stop.new(original_vrp.services[index])
                }
              else
                un
              end
            else
              un
            end
          }
        solution = Models::Solution.new(routes: new_routes, unassigned_stops: new_unassigned)
        solution.parse(original_vrp, compute_dimensions: true)
      end
      module_function :clique_cluster_candidate?, :clique_cluster, :zip_cluster, :unzip_cluster
    end
  end
end
