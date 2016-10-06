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
  class Vrp < Base
    field :preprocessing_cluster_threshold, default: nil
    field :preprocessing_prefer_short_segment, default: false
    field :resolution_duration, default: nil
    field :resolution_iterations, default: nil
    field :resolution_iterations_without_improvment, default: nil
    field :resolution_stable_iterations, default: nil
    field :resolution_stable_coefficient, default: nil
    field :resolution_initial_time_out, default: nil
    field :resolution_time_out_multiplier, default: nil
    validates_numericality_of :preprocessing_cluster_threshold, allow_nil: true
    validates_numericality_of :resolution_duration, allow_nil: true
    validates_numericality_of :resolution_iterations, allow_nil: true
    validates_numericality_of :resolution_iterations_without_improvment, allow_nil: true
    validates_numericality_of :resolution_stable_iterations, allow_nil: true
    validates_numericality_of :resolution_stable_coefficient, allow_nil: true
    validates_numericality_of :resolution_initial_time_out, allow_nil: true
    validates_numericality_of :resolution_time_out_multiplier, allow_nil: true

    has_many :matrices, class_name: 'Models::Matrix'
    has_many :points, class_name: 'Models::Point'
    has_many :units, class_name: 'Models::Unit'
    has_many :rests, class_name: 'Models::Rest'
    has_many :vehicles, class_name: 'Models::Vehicle'
    has_many :services, class_name: 'Models::Service'
    has_many :shipments, class_name: 'Models::Shipment'

    def self.create(hash, delete = true)
      Models.delete_all if delete
      super(hash)
    end

    def configuration=(configuration)
      self.preprocessing = configuration[:preprocessing] if configuration[:preprocessing]
      self.resolution = configuration[:resolution] if configuration[:resolution]
    end

    def resolution=(resolution)
      self.resolution_duration = resolution[:duration]
      self.resolution_iterations = resolution[:iterations]
      self.resolution_iterations_without_improvment = resolution[:iterations_without_improvment]
      self.resolution_stable_iterations = resolution[:stable_iterations]
      self.resolution_stable_coefficient = resolution[:stable_coefficient]
      self.resolution_initial_time_out = resolution[:initial_time_out]
      self.resolution_time_out_multiplier = resolution[:time_out_multiplier]
    end

    def preprocessing=(preprocessing)
      self.preprocessing_cluster_threshold = preprocessing[:cluster_threshold]
      self.preprocessing_prefer_short_segment = preprocessing[:prefer_short_segment]
    end

    def need_matrix_time?
      services.find{ |service|
        !service.activity.timewindows.empty? || service.late_multiplier != 0
      } ||
      shipments.find{ |shipment|
        !shipments.pickup.timewindows.empty? || shipments.pickup.late_multiplier != 0 ||
        !shipments.delivery.timewindows.empty? || shipments.delivery.late_multiplier != 0
      }
    end

    def need_matrix_distance?
      false
    end
  end
end
