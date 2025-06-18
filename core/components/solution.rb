module Core
  module Components
    module Solution
      def check_solutions_consistency(expected_value, solutions)
        solutions.each{ |solution|
          if solution.routes.any?{ |route| route.stops.any?{ |a| a.info.waiting_time < 0 } }
            log 'Computed waiting times are invalid', level: :warn
            raise 'Computed waiting times are invalid' if ENV['APP_ENV'] != 'production'
          end

          waiting_times = solution.routes.map{ |route| route.info.total_waiting_time }.compact
          durations =
            solution.routes.map{ |route|
              route.stops.map{ |stop|
                stop.info.departure_time && (stop.info.departure_time - stop.info.begin_time)
              }.compact
            }
          previous_point_id = nil
          setup_durations =
            solution.routes.map{ |route|
              route.stops.map{ |stop|
                next if stop.type == :rest

                setup = (previous_point_id.nil? || previous_point_id != stop.activity.point_id) &&
                        stop.activity.setup_duration_on(route.vehicle) || 0
                previous_point_id = stop.activity.point_id
                setup
              }.compact
            }
          total_time = solution.info.total_time || 0
          total_travel_time = solution.info.total_travel_time || 0
          if total_time != (total_travel_time || 0) +
                           waiting_times.sum +
                           (setup_durations.flatten.reduce(&:+) || 0) +
                           (durations.flatten.reduce(&:+) || 0)

            log_string = 'Computed times are invalid'
            tags = {
              total_time: total_time,
              total_travel_time: total_travel_time,
              waiting_time: waiting_times.sum,
              setup_durations: setup_durations.flatten.reduce(&:+),
              durations: durations.flatten.reduce(&:+)
            }
            log log_string, tags.merge(level: :warn)
            # raise 'Computed times are invalid' if ENV['APP_ENV'] != 'production'
          end

          nb_assigned = solution.count_assigned_services
          nb_unassigned = solution.count_unassigned_services

          next if expected_value == nb_assigned + nb_unassigned

          tags = { expected: expected_value, assigned: nb_assigned, unassigned: nb_unassigned }
          log 'Wrong number of visits returned in result', tags.merge(level: :warn)
          raise 'Wrong number of visits returned in result' if ENV['APP_ENV'] != 'production'
        }
      end
      module_function :check_solutions_consistency
    end
  end
end
