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

    def flat_time(matrix_size = nil)
      flat_dimension(:time, matrix_size)
    end

    def flat_distance(matrix_size = nil)
      flat_dimension(:distance, matrix_size)
    end

    def flat_value
      matrix = value
      return [] if matrix.nil?

      flat_dimension(:value)
    end

    def clear_flatten_cache!
      DIMENSIONS.each do |dimension|
        remove_instance_variable(:"@_flat_#{dimension}") if
          instance_variable_defined?(:"@_flat_#{dimension}")
        remove_instance_variable(:"@_flat_#{dimension}_id") if
          instance_variable_defined?(:"@_flat_#{dimension}_id")
      end
    end

    private

    def flat_dimension(dimension, zero_fill_size = nil)
      matrix = send(dimension)
      return Array.new(zero_fill_size**2, 0) if matrix.nil? && zero_fill_size
      return [] if matrix.nil?

      cache_key = :"@_flat_#{dimension}"
      version_key = :"@_flat_#{dimension}_id"
      source_id = matrix.__id__
      if instance_variable_get(version_key) == source_id && (cached = instance_variable_get(cache_key))
        return cached
      end

      flattened = matrix.flatten
      instance_variable_set(cache_key, flattened)
      instance_variable_set(version_key, source_id)
      flattened
    end
  end
end
