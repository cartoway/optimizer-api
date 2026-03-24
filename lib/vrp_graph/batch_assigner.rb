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
# Assigns routes to batches (lots) with max size constraint, maximizing proximity.
# Uses greedy algorithm; optional OR-Tools CP-SAT when gem available.

module VrpGraph
  class BatchAssigner
    def initialize(graph, solution, max_routes_per_batch: 5, route_vehicle_skills: {})
      @graph = graph
      @solution = solution
      @max_routes_per_batch = max_routes_per_batch
      @route_vehicle_skills = route_vehicle_skills
    end

    # @return [Hash] route_index => batch_index
    def assign
      if defined?(ORTools) && defined?(ORTools::Sat::CpSolver)
        assign_with_ortools
      else
        assign_greedy
      end
    end

    private

    def assign_greedy
      n_routes = @solution.routes.size
      batches = []
      route_to_batch = {}

      # Build proximity matrix between routes (number of shared graph neighbors)
      proximity = build_proximity_matrix

      # Greedy: assign routes to batches, always adding to the batch that maximizes total proximity
      n_routes.times do |r|
        best_batch = nil
        best_score = -Float::INFINITY

        batches.each_with_index do |batch, bi|
          next if batch.size >= @max_routes_per_batch

          score = batch.sum{ |other| proximity[r][other] || 0 }
          if score > best_score
            best_score = score
            best_batch = bi
          end
        end

        if best_batch && best_score >= 0
          batches[best_batch] << r
          route_to_batch[r] = best_batch
        else
          route_to_batch[r] = batches.size
          batches << [r]
        end
      end

      route_to_batch
    end

    # Proximity = number of graph KNN links between services of the two routes,
    # filtered through the vehicle's compatible skill-set graphs.
    def build_proximity_matrix
      n = @solution.routes.size
      prox = Array.new(n){ Array.new(n, 0) }
      use_filtered = @route_vehicle_skills.any? && @graph.respond_to?(:neighbors_for_service_with_vehicle_skills)

      @solution.routes.each_with_index do |route_a, i|
        ids_a = route_stop_service_ids(route_a)
        v_skills_a = @route_vehicle_skills[i]

        @solution.routes.each_with_index do |route_b, j|
          next if i >= j

          ids_b = route_stop_service_ids(route_b)
          count = 0
          ids_a.each_key do |sid|
            neighbors =
              if use_filtered && v_skills_a&.any?
                @graph.neighbors_for_service_with_vehicle_skills(sid, v_skills_a)
              else
                @graph.neighbors_for_service(sid)
              end
            (neighbors || []).each do |nb_sid|
              count += 1 if ids_b.key?(nb_sid)
            end
          end
          prox[i][j] = prox[j][i] = count
        end
      end
      prox
    end

    def route_stop_service_ids(route)
      route.stops.filter_map(&:service_id).compact.each_with_object({}) { |sid, h| h[sid] = true }
    end

    def assign_with_ortools
      # Placeholder: when or-tools is available, implement CP model
      assign_greedy
    end
  end
end
