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
module VrpAsJson
  extend ActiveSupport::Concern

  def empty_json(options = nil)
    vrp = {
      'name' => self.name,
      'configuration' => self.configuration.as_json(options),
      'points' => [], 'services' => [], 'vehicles' => []
    }

    vrp.to_json
  end
end

module SolutionStopAsJson
  extend ActiveSupport::Concern

  def as_json(options = nil)
    stop = super

    return stop unless self.is_a? Models::Solution::Stop

    stop.delete('id') if self.type == :depot
    stop
  end
end
