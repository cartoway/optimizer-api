# frozen_string_literal: true

# Copyright © Cartoway, 2026
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
module VrpGraph
  # Checks time window compatibility: two services are incompatible if
  # duration of first makes it impossible to serve both in either order.
  # Uses only timewindows and duration (no travel time).
  module TimewindowCompatibility
    module_function

    # @param vrp [Models::Vrp]
    # @return [Hash] nested: incompat[service_id_a][service_id_b] = true (bidirectional)
    def compute_incompatibilities(vrp)
      incompat = Hash.new { |h, k| h[k] = {} }
      services = vrp.services.to_a

      services.each_with_index do |s1, i|
        j = i + 1
        while j < services.size
          s2 = services[j]
          if s1&.activity && s2&.activity && !can_sequence?(s1, s2) && !can_sequence?(s2, s1)
            id_a = s1.id
            id_b = s2.id
            incompat[id_a][id_b] = true
            incompat[id_b][id_a] = true
          end
          j += 1
        end
      end
      incompat
    end

    # Can we serve first then second? (arrival at second feasible, travel_time = 0)
    def can_sequence?(first, second)
      tws_first = first.activity&.timewindows.to_a
      tws_second = second.activity&.timewindows.to_a
      # No timewindows means no constraint: necessarily compatible
      return true if tws_first.empty? || tws_second.empty?

      duration_first = first.activity&.duration_on || 0
      setup_first = first.activity&.setup_duration_on || 0

      tws_first.any? do |tw1|
        # Earliest we can leave first and arrive at second (no travel). We can wait if we arrive early.
        earliest_arrival = (tw1.start || 0) + duration_first + setup_first

        tws_second.any? do |tw2|
          next true if tw2.end.nil? # No end: necessarily compatible

          earliest_arrival <= tw2.end
        end
      end
    end
  end
end
