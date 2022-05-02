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
    class Stop < Base
      class Info < Base
        field :id, as_json: :none
        field :day_week_num
        field :day_week

        field :travel_distance
        field :travel_time
        field :travel_value

        field :waiting_time, default: 0
        field :begin_time, default: 0
        field :end_time
        field :departure_time, default: 0

        field :current_distance, default: 0

        # Fields related to the vehicle performing the current leg
        field :router_mode
        field :speed_multiplier

        def set_schedule(vrp, vehicle)
          return unless vrp.schedule?

          size_weeks = (vrp.configuration.schedule.range_indices[:end].to_f / 7).ceil.to_s.size
          week = Helper.string_padding(vehicle.global_day_index / 7 + 1, size_weeks)
          self.day_week_num = "#{vehicle.global_day_index % 7}_#{week}"
          self.day_week = "#{OptimizerWrapper::WEEKDAYS[vehicle.global_day_index % 7]}_#{week}"
        end
      end
    end
  end
end
