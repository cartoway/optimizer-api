# Copyright © Mapotempo, 2021
#
# This file is part of Mapotempo.
#
# Mapotempo is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Mapotempo is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Mapotempo. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#
require './models/base'

module Models
  class Solution < Base
    class Route < Base
      MISSION_TYPES = [:service, :pickup, :delivery].freeze
      field :geometry

      has_many :stops, class_name: 'Models::Solution::Stop'
      has_many :initial_loads, class_name: 'Models::Solution::Load'

      belongs_to :cost_info, class_name: 'Models::Solution::CostInfo'
      belongs_to :info, class_name: 'Models::Solution::Route::Info'
      belongs_to :vehicle, class_name: 'Models::Vehicle', as_json: :id, vrp_result: :hide

      def initialize(options = {})
        options = { info: {}, cost_info: {} }.merge(options)
        super(options)
      end

      def vrp_result(options = {})
        options[:vehicle] = vehicle
        hash = super(options)
        hash['activities'] = hash.delete('stops')
        compute_setup_times(hash)
        hash['cost_details'] = hash.delete('cost_info')
        hash['detail'] = hash.delete('info')
        hash.merge!(info.vrp_result(options))
        hash.merge!(vehicle.vrp_result(options))
        hash.delete_if{ |_k, v| v.nil? }
        hash
      end

      redefine_method('stops=') do |stops|
        stops.map!{ |stop|
          stop = Models::Solution::Stop.new(stop) if stop.is_a? Hash
          stop.info.router_mode ||= vehicle&.router_mode
          stop.info.speed_multiplier ||= vehicle&.speed_multiplier
          stop.compute_info_end_time(vehicle: vehicle)
          stop
        }
      end

      def count_services
        stops.count(&:service_id)
      end

      def insert_stop(_vrp, stop, index, idle_time = 0)
        stops.insert(index, stop)
        shift_route_times(idle_time + stop.activity.duration, index)
      end

      def compute_setup_times(hash)
        previous_point_id = nil
        stops.each.with_index{ |stop, stop_index|
          hash['activities'][stop_index]['setup_time'] =
            if MISSION_TYPES.include?(stop.type) && stop.activity.point_id != previous_point_id
              stop.activity.setup_duration_on(vehicle)
            else
              0
            end
          previous_point_id = stop.activity.point_id if stop.activity.point_id
        }
      end

      def shift_route_times(shift_amount, shift_start_index = 0)
        return if shift_amount == 0

        raise 'Cannot shift the route, there are not enough stops' if shift_start_index > self.stops.size

        current_shift = shift_amount
        self.info.start_time += shift_amount if shift_start_index == 0
        self.stops.each_with_index{ |stop, index|
          next if index <= shift_start_index

          active_tw = stop.active_timewindow
          if active_tw && (active_tw.safe_end(stop.activity.lateness_allowed?) - stop.info.begin_time < current_shift)
            raise 'Current implementation of shift route times should not happen in the context of tight timewindows'
          end

          if stop.info.waiting_time > 0
            waiting_resorb = [stop.info.waiting_time - current_shift, 0].max
            current_shift = [current_shift - waiting_resorb, 0].max
            stop.info.waiting_time -= waiting_resorb
          end

          stop.info.begin_time += current_shift
          stop.info.end_time += current_shift if stop.info.end_time
          stop.info.departure_time += current_shift if stop.info.departure_time
        }
        self.info.end_time += current_shift if self.info.end_time
      end
    end
  end
end
