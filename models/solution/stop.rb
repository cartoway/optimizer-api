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
require './models/solution/parsers/stop_parser'

module Models
  class Solution < Base
    class Stop < Base
      field :id
      field :type
      field :alternative
      field :reason, default: nil
      # TODO: The following fields should be merged into id in v2
      field :service_id
      field :pickup_shipment_id
      field :delivery_shipment_id
      field :rest_id
      field :skills, default: [], vrp_result: :hide
      field :original_skills, default: [], vrp_result: :hide
      field :visit_index
      field :exclusion_cost

      has_many :loads, class_name: 'Models::Solution::Load'
      belongs_to :activity, class_name: 'Models::Activity'
      belongs_to :info, class_name: 'Models::Solution::Stop::Info', vrp_result: :hide

      def initialize(object, options = {})
        options = { info: {} }.merge(options)
        parsed_object =
          case object.class.to_s
          when 'Models::Service'
            Parsers::ServiceParser.parse(object, options)
          when 'Models::Rest'
            Parsers::RestParser.parse(object, options)
          when 'Models::Point'
            Parsers::PointParser.parse(object, options)
          when 'Hash'
            object # Allow direct loading of json solution
          else

            raise "Unknown stop class: #{object.class.to_s} #{object.inspect}"
          end
        raise 'A route stop cannot be nil' unless parsed_object

        super(parsed_object)
      end

      def vrp_result(options = {})
        if info.travel_time&.positive?
          options[:apply] ||= []
          options[:apply] << [:setup]
        end
        filter_fake_timewindow
        hash = super(options)
        hash['original_service_id'] = id
        hash.merge!(info.vrp_result(options))
        hash['point_id'] = self.activity.point_id
        hash['detail'] = hash.delete('activity')
        hash['detail']['skills'] = build_skills
        hash['detail']['internal_skills'] = self.skills
        hash['detail']['quantities'] = loads.vrp_result(options)
        hash['detail']['router_mode'] = hash.delete('router_mode')
        hash['detail']['speed_multiplier'] = hash.delete('speed_multiplier')
        hash.delete_if{ |_k, v| v.nil? }
        hash
      end

      def compute_info_end_time(options)
        info.end_time = info.begin_time + activity.duration_on(service_id ? options[:vehicle] : nil)
        info.departure_time = info.end_time
      end

      def build_skills
        return [] unless self.skills.any?

        all_skills = self.skills - self.original_skills
        skills_to_output = []
        vehicle_cluster = all_skills.find{ |sk| sk.to_s.include?('vehicle_partition_') }
        skills_to_output << vehicle_cluster.to_s.split('_')[2..-1].join('_') if vehicle_cluster
        work_day_cluster = all_skills.find{ |sk| sk.to_s.include?('work_day_partition_') }
        skills_to_output << work_day_cluster.to_s.split('_')[3..-1].join('_') if work_day_cluster
        skills_to_output += all_skills.select{ |sk| sk.to_s.include?('cluster ') }
        skills_to_output += self.original_skills
        skills_to_output
      end

      def filter_fake_timewindow
        return if activity.timewindows.size != 1

        activity.timewindows = [] if activity.timewindows.first.start == 0 && activity.timewindows.first.end.nil?
      end

      def active_timewindow
        return nil if activity.timewindows.empty?

        if info.waiting_time > 0
          active_tw =
            activity.timewindows.select{ |tw| tw.start > info.begin_time }.min_by{ |tw|
              tw.start - info.begin_time
            }
          return active_tw
        end

        active_tw =
          activity.timewindows.find{ |tw|
            tw.start <= info.begin_time && info.begin_time <= tw.safe_end
          }
        return active_tw if active_tw

        activity.timewindows.find{ |tw|
          tw.start <= info.begin_time && info.begin_time <= tw.safe_end(activity.lateness_allowed?)
        }
      end
    end

    class StopDepot < Stop
      field :type

      has_many :loads, class_name: 'Models::Solution::Load'
      belongs_to :activity, class_name: 'Models::Activity'
      belongs_to :info, class_name: 'Models::Solution::Stop::Info', vrp_result: :hide
    end
  end
end
