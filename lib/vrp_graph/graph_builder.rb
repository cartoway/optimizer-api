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
# Graph builder for VRP services: Delaunay triangulation, compatibility checks, K-NN.
# Uses travel time matrix (routing or precomputed).

require_relative 'delaunay_adapter'
require_relative 'skills_compatibility'
require_relative 'timewindow_compatibility'
require_relative 'capacity_compatibility'
require_relative 'knn_neighborhood'

module VrpGraph
  # Orchestrates Delaunay triangulation, compatibility checks, K-NN, and Graph model creation.
  class GraphBuilder
    def initialize(vrp, options = {})
      @vrp = vrp
      @matrix_id = options[:matrix_id] || vrp.vehicles.first&.matrix_id
    end

    def build
      t_build_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      services = @vrp.services.reject{ |s| s.activity.nil? || s.activity.point.nil? }
      return nil if services.empty?

      # Unique points (1 point can have several services). Source: vrp.points filtered by usage in services.
      used_point_ids = services.map { |s| s.activity.point_id || s.activity.point&.id }.compact.uniq
      graph_points = @vrp.points.select { |p| used_point_ids.include?(p.id) }
      # Fallback if vrp.points is empty: derive from services
      graph_points = services.map{ |s| s.activity.point }.compact.uniq(&:id) if graph_points.empty?

      point_by_index = graph_points.each_with_index.to_h { |p, i| [i, p] }
      services_by_point_id = {}
      services.each do |s|
        pid = (s.activity.point_id || s.activity.point&.id).to_s
        (services_by_point_id[pid] ||= []) << s
      end

      # One coordinate list per point (no duplicate points in Delaunay)
      delaunay_points = graph_points.map { |p| point_location_coords(p) }
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      delaunay_edges = DelaunayAdapter.compute_edges(delaunay_points)
      log_duration('graph_delaunay', t0)

      # Build nodes (keyed by point_id) and map service_id -> point_id
      nodes = {}
      service_point = {}
      services.each do |s|
        activity = s.activity
        pt = activity.point
        next unless pt

        loc = pt.location
        pid = pt.id

        node = (nodes[pid] ||= {
          point: { lat: loc&.lat, lon: loc&.lon },
          services: []
        })

        node[:services] << {
          id: s.id,
          skills: s.skills.to_a.map(&:to_s),
          timewindows: (activity.timewindows || []).map{ |tw| { start: tw.start, end: tw.end } },
          duration: activity.duration,
          setup_duration: activity.setup_duration,
          quantities: s.quantities.map{ |q|
            {
              unit_id: q.unit_id,
              value: q.value,
              pickup: q.pickup,
              delivery: q.delivery,
              fill: q.fill,
              empty: q.empty
            }
          }
        }

        service_point[s.id] = pid
      end

      # Use VRP matrix only if already present (no compute). For K-NN without matrix: rectangular via router only.
      vrp_matrix = @vrp.matrices.find{ |m| m.id == @matrix_id }
      vrp_time_matrix = vrp_matrix&.time

      # Skills incompatibilities
      t2 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      skills_incompat = SkillsCompatibility.compute_incompatibilities(@vrp)
      log_duration('graph_skills_compatibility', t2)

      # Timewindow incompatibilities (timewindows + duration only, no travel time)
      t3 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      tw_incompat = TimewindowCompatibility.compute_incompatibilities(@vrp)
      log_duration('graph_timewindow_compatibility', t3)

      # Capacity incompatibilities (pairs at different points: sum of quantities > max vehicle capacity)
      t4 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cap_incompat = CapacityCompatibility.compute_incompatibilities(@vrp)
      log_duration('graph_capacity_compatibility', t4)

      # Merge nested incompatibilities (each is incompat[a][b] = true)
      all_incompat = merge_nested_incompat(skills_incompat, tw_incompat, cap_incompat)

      # Map Delaunay edges (point indices) to point IDs and filter: keep edge if at least one service pair is compatible
      t5 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      original_degree = Hash.new(0)
      delaunay_edges.each do |i, j|
        pid_a = point_by_index[i]&.id
        pid_b = point_by_index[j]&.id
        next unless pid_a && pid_b && pid_a != pid_b

        original_degree[pid_a] += 1
        original_degree[pid_b] += 1
      end

      edges = []
      delaunay_edges.each do |i, j|
        pid_a = point_by_index[i]&.id
        pid_b = point_by_index[j]&.id
        next unless pid_a && pid_b
        next if pid_a == pid_b

        # Edge is valid if at least one (service at A, service at B) pair is not incompatible
        compatible =
          (services_by_point_id[pid_a] || []).any? { |s_a|
            (services_by_point_id[pid_b] || []).any? { |s_b|
              !all_incompat.dig(s_a.id, s_b.id)
            }
          }
        next unless compatible

        edges << [pid_a, pid_b]
      end

      # Track degree per point after filtering
      filtered_degree = Hash.new(0)
      edges.each do |a, b|
        filtered_degree[a] += 1
        filtered_degree[b] += 1
      end

      # Points that lost at least one Delaunay edge
      repaired_nodes = {}
      original_degree.each do |pid, deg|
        next if deg <= (filtered_degree[pid] || 0)

        repaired_nodes[pid] = true
      end

      removed = delaunay_edges.size - edges.size
      log_duration(
        'graph_edges_filter',
        t5,
        "delaunay=#{delaunay_edges.size} kept=#{edges.size} removed=#{removed} repaired_nodes=#{repaired_nodes.size}"
      )

      # K-NN: use square matrix in memory when available; otherwise compute rectangular (repaired × other) via router only.
      t6 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      repaired_pids = repaired_nodes.keys
      all_pids = graph_points.map { |p| p.id }
      other_pids = all_pids - repaired_pids
      point_incompat = build_point_incompat(services_by_point_id, all_incompat, all_pids)
      pid_to_point = graph_points.to_h { |p| [p.id, p] }
      knn_matrix =
        if vrp_time_matrix
          { square: vrp_time_matrix, pid_to_point: pid_to_point }
        elsif repaired_pids.any? && other_pids.any?
          { rectangular: compute_knn_rectangular_via_router(repaired_pids, other_pids, pid_to_point) }
        else
          { rectangular: [] }
        end
      k_per_point = (repaired_pids.empty? || other_pids.empty?) ? 0 : other_pids.size
      knn_neighbors = KnnNeighborhood.compute_knn_points(
        repaired_pids, other_pids, knn_matrix, point_incompat, k: k_per_point
      )
      # Add K-NN arcs as edges (point-to-point)
      edge_set = edges.map{ |a, b| [a, b].sort }.to_h{ |p| [p, true] }
      knn_added = 0
      knn_segments = []
      knn_edge_indices = []
      knn_neighbors.each do |pid_a, neighbor_pids|
        next unless repaired_nodes[pid_a]

        missing = (original_degree[pid_a] || 0) - (filtered_degree[pid_a] || 0)
        next if missing <= 0

        added = 0
        neighbor_pids.each do |pid_b|
          pair = [pid_a, pid_b].sort
          next if edge_set.key?(pair)

          edges << [pid_a, pid_b]
          edge_set[pair] = true
          knn_added += 1
          added += 1

          node_a = nodes[pid_a]
          node_b = nodes[pid_b]
          if node_a && node_b
            pa = node_a[:point] || node_a['point']
            pb = node_b[:point] || node_b['point']
            if pa && pb && pa[:lat] && pa[:lon] && pb[:lat] && pb[:lon]
              knn_segments << [pa[:lat].to_f, pa[:lon].to_f, pb[:lat].to_f, pb[:lon].to_f]
              knn_edge_indices << (edges.size - 1)
            end
          end

          break if added >= missing
        end
      end

      add_knn_traces!(edges, knn_segments, knn_edge_indices) if knn_segments.any?

      knn_matrix_type = vrp_time_matrix ? 'square_in_memory' : "rectangular=#{repaired_pids.size}x#{other_pids.size}"
      log_duration('graph_knn', t6, "knn_added=#{knn_added} #{knn_matrix_type}")

      log_duration('graph_build_total', t_build_start)

      Models::Graph.new(
        nodes: nodes,
        edges: edges,
        incompatibilities: nested_incompat_to_pairs(all_incompat),
        knn_neighbors: knn_neighbors,
        metadata: {
          delaunay_built_at: Time.now.iso8601,
          matrix_id_used: @matrix_id
        }
      )
    end

    private

    def merge_nested_incompat(*hashes)
      result = Hash.new { |h, k| h[k] = {} }
      hashes.each do |h|
        h.each do |a, inner|
          inner.each_key { |b| result[a][b] = true }
        end
      end
      result
    end

    def nested_incompat_to_pairs(nested)
      pairs = []
      seen = {}
      nested.each do |a, inner|
        inner.each_key do |b|
          pair = [a.to_s, b.to_s].sort
          next if seen[pair]

          seen[pair] = true
          pairs << pair
        end
      end
      pairs
    end

    def point_coords(service)
      loc = service.activity.point&.location
      [loc&.lon || 0.0, loc&.lat || 0.0]
    end

    # [lon, lat] for Delaunay (one entry per point, no duplicates)
    def point_location_coords(point)
      loc = point&.location
      [loc&.lon.to_f || 0.0, loc&.lat.to_f || 0.0]
    end

    def log_duration(label, start_time, extra = nil)
      return unless defined?(OptimizerLogger)

      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)
      msg = "VrpGraph #{label}: #{elapsed_ms}ms"
      msg += " (#{extra})" if extra
      OptimizerLogger.log(msg, level: :info)
    end

    # Point-level incompatibility: [pid_a, pid_b] is incompatible iff no (service at A, service at B) pair is compatible.
    def build_point_incompat(services_by_point_id, all_incompat, all_pids)
      incompat = {}
      all_pids.each do |pid_a|
        all_pids.each do |pid_b|
          next if pid_a == pid_b

          compatible =
            (services_by_point_id[pid_a] || []).any? { |s_a|
              (services_by_point_id[pid_b] || []).any? { |s_b|
                !all_incompat.dig(s_a.id, s_b.id)
              }
            }
          incompat[[pid_a, pid_b].sort] = true unless compatible
        end
      end
      incompat
    end

    # Compute rectangular matrix (repaired × other) via router when no square matrix is available.
    def compute_knn_rectangular_via_router(repaired_pids, other_pids, pid_to_point)
      return [] unless @vrp.router
      return [] unless defined?(OptimizerWrapper) && OptimizerWrapper.config[:router]&.dig(:url)

      from_points =
        repaired_pids.map { |pid|
          pt = pid_to_point[pid]
          pt&.location ? [pt.location.lat.to_f, pt.location.lon.to_f] : nil
        }.compact
      to_points =
        other_pids.map { |pid|
          pt = pid_to_point[pid]
          pt&.location ? [pt.location.lat.to_f, pt.location.lon.to_f] : nil
        }.compact
      return [] if from_points.size != repaired_pids.size || to_points.size != other_pids.size

      vehicle = @vrp.vehicles.first
      mode = vehicle&.router_mode&.to_sym || :car
      router_matrices = @vrp.router.matrix(
        OptimizerWrapper.config[:router][:url],
        mode,
        [:time],
        from_points,
        to_points,
        vehicle&.router_options || {}
      )
      router_matrices&.first || []
    end

    def add_knn_traces!(edges, segments, edge_indices)
      return unless @vrp.router
      return unless defined?(OptimizerWrapper) && OptimizerWrapper.config[:router]&.dig(:url)

      vehicle = @vrp.vehicles.first
      mode = vehicle&.router_mode&.to_sym || :car
      dimension = vehicle&.router_dimension || :time
      options = vehicle&.router_options || {}

      info = @vrp.router.compute_batch(
        OptimizerWrapper.config[:router][:url],
        mode,
        dimension,
        segments,
        false, # polyline: false -> raw coordinates
        options
      )
      return unless info

      info.each_with_index do |data, idx|
        next unless data

        _dist, _time, trace = data
        next if trace.nil? || !trace.is_a?(Array) || trace.empty?

        edge_idx = edge_indices[idx]
        next unless edge_idx

        a, b = edges[edge_idx][0], edges[edge_idx][1]
        edges[edge_idx] = [a, b, trace]
      end
    rescue StandardError => e
      log_duration('graph_knn_geometry_error', Process.clock_gettime(Process::CLOCK_MONOTONIC), e.message)
    end
  end
end
