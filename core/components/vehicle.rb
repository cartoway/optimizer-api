module Core
  module Components
    module Vehicle
      def adjust_vehicles_duration(vrp)
        vrp.vehicles.select{ |v| v.duration? && !v.rests.empty? }.each{ |v|
          v.rests.each{ |r|
            v.duration += r.duration
          }
        }
      end
      module_function :adjust_vehicles_duration
    end
  end
end
