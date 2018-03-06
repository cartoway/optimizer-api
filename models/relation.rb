# Copyright © Mapotempo, 2016
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
  class Relation < Base
    field :type, default: :same_route
    field :lapse, default: nil
    field :linked_ids, default: []
    field :linked_vehicles_ids, default: []

    validates_numericality_of :lapse, allow_nil: true
    validates_inclusion_of :type, :in => %i(same_route sequence order minimum_day_lapse maximum_day_lapse shipment meetup maximum_duration_lapse force_first never_first force_end vehicle_group_duration)
  end
end
