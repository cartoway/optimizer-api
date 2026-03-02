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
# Checks skills compatibility between services: two services are incompatible
# if no vehicle can serve both (skills never appear together on a vehicle).
module VrpGraph
  module SkillsCompatibility
    module_function

    # @param vrp [Models::Vrp]
    # @return [Hash] nested: incompat[service_id_a][service_id_b] = true (bidirectional)
    def compute_incompatibilities(vrp)
      incompat_skills = build_incompat_skills(vrp.vehicles)
      incompat = Hash.new { |h, k| h[k] = {} }
      services = vrp.services.to_a

      services.each_with_index do |s1, i|
        j = i + 1
        while j < services.size
          s2 = services[j]
          if services_incompatible?(s1, s2, incompat_skills)
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

    # incompat_skills[skill1][skill2] = true when skill1 and skill2 never appear together on a vehicle.
    # Factor by unique skill config (vehicle.skills.first) to avoid redundant iterations.
    def build_incompat_skills(vehicles)
      unique_skill_configs = vehicles.map { |v| v.skills.first.to_a.map(&:to_s).sort }.uniq

      compatible_pairs = {}
      unique_skill_configs.each do |skills|
        skills.each do |a|
          skills.each do |b|
            compatible_pairs[[a, b].sort] = true
          end
        end
      end

      all_skills = unique_skill_configs.flatten.uniq

      incompat = Hash.new { |h, k| h[k] = {} }
      all_skills.each do |a|
        all_skills.each do |b|
          next if a == b
          next if compatible_pairs[[a, b].sort]

          incompat[a][b] = true
        end
      end
      incompat
    end

    def services_incompatible?(s1, s2, incompat_skills)
      sk1 = s1.skills.to_a.map(&:to_s)
      sk2 = s2.skills.to_a.map(&:to_s)
      sk1.any? { |a| sk2.any? { |b| incompat_skills[a].key?(b) } }
    end
  end
end
