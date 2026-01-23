# Copyright © Mapotempo, 2017
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
  class Route < Base
    field :mission_ids, default: []
    field :day_index
    belongs_to :vehicle, class_name: 'Models::Vehicle', as_json: :id

    has_many :missions, class_name: 'Models::Mission', as_json: :ids

    def initialize(hash)
      hash[:missions] ||= []
      if hash[:mission_ids].present?
        hash[:missions] +=
          hash[:mission_ids]&.map{ |mission_id|
            Models::Service.find_by_id(mission_id) ||
              Models::ReloadDepot.find_by_id(mission_id) ||
              Models::Rest.find_by_id(mission_id)
          }&.compact
        hash.delete(:mission_ids)
      end
      super(hash)
    end

    def mission_ids
      missions.map{ |mission| mission.original_id || mission.id }
    end
  end
end
