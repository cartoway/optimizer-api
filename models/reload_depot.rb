# Copyright © Cartoway, 2025
#
# This file is part of Cartoway Optimizer.
#
# Cartoway Planner is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Cartoway Optimizer is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Cartoway Optimizer. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#
require './models/base'

module Models
  class ReloadDepot < Activity
    field :id
    field :original_id, default: nil

    field :duration, default: 0
    field :type, default: :reload_depot, type: Symbol
    field :late_multiplier, default: 0, vrp_result: :hide
    field :exclusion_cost, default: nil, vrp_result: :hide

    belongs_to :point, class_name: 'Models::Point', as_json: :id, vrp_result: :hide
    has_many :timewindows, class_name: 'Models::Timewindow'

    def initialize(hash)
      hash[:original_id] ||= hash[:id]

      super(hash)
    end

    def vrp_result(options = {})
      hash = super(options)

      if options[:vehicle]
        hash[:duration] = duration_on(options[:vehicle])
      end

      if self.point # Rest inherits from activity
        hash['lat'] = point.location&.lat
        hash['lon'] = point.location&.lon
      end
      hash
    end

    def duration_on(vehicle = nil)
      case vehicle
      when nil
        duration
      when Models::Vehicle
        duration * vehicle.coef_service + vehicle.additional_service
      else
        raise 'Unknown object type for activity duration calculation'
      end
    end

    def setup_duration_on(_vehicle = nil)
      0
    end
  end
end
