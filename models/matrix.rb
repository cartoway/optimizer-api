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
  DIMENSIONS = %i[time distance value].freeze

  class Matrix < Base
    field :id
    fields :time, :distance, :value

    def self.dimensions
      DIMENSIONS
    end

    DIMENSIONS.each do |dimension|
      define_method "integer_#{dimension}" do |max_value = nil|
        matrix = send(dimension)
        return matrix if matrix.nil? || matrix.first.all? { |v| v.is_a?(Integer) } && max_value.nil?

        matrix.map { |row|
          row.map { |v|
            v = [v, max_value].min if max_value
            v&.round(0)
          }
        }
      end
    end
  end
end
