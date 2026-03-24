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
# Nodes are keyed by service_id (one node per service). Edges are service-level pairs.
# Delaunay and KNN operate at point level, then results are expanded to service-level.
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

    # Builds a single graph from all services (backward-compatible entry point).
    def build
      all_services = @vrp.services.reject{ |s| s.activity.nil? || s.activity.point.nil? }
      return nil if all_services.empty?

      shared = precompute_shared(all_services)
      build_for_services(all_services, shared, label: nil)
    end

    # Builds one Delaunay graph per unique skill-set (sorted combination of
    # skills) found across services. Each graph includes all services whose
    # skill-set shares at least one skill with the graph key (intersection),
    # and have no extra skills through union of skills.
    # plus all no-skill services as universal bridges.
    # Returns a Models::MultiGraph wrapping { skill_set_key => Models::Graph }.
    def build_per_skill
      t_total = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      all_services = @vrp.services.reject{ |s| s.activity.nil? || s.activity.point.nil? }
      return nil if all_services.empty?

      shared = precompute_shared(all_services)

      groups = all_services.group_by{ |s| s.skills.to_a.map(&:to_s).sort }
      no_skill_services = groups.delete([]) || []

      if groups.empty?
        graph = build_for_services(no_skill_services, shared, label: nil)
        log_duration('graph_per_skill_total', t_total, 'no_skills_single_graph')
        return graph && Models::MultiGraph.new(graphs: { nil => graph })
      end

      graphs = {}
      groups.each_key do |skill_set|
        key = skill_set.join(',')
        compatible = []
        groups.each do |other_set, svcs|
          compatible.concat(svcs) if (skill_set & other_set).any? && (skill_set | other_set).size == skill_set.size
        end
        compatible.concat(no_skill_services)
        graphs[key] = build_for_services(compatible, shared, label: key)
      end

      log_duration('graph_per_skill_total', t_total, "skill_sets=#{groups.size} graphs=#{graphs.size}")

      Models::MultiGraph.new(graphs: graphs)
    end

    private

    # Pre-computes state shared across all per-skill sub-builds:
    # incompatibilities (tw+capacity), vehicle_skill_sets, time matrix.
    # Skills incompatibility is handled structurally by the per-skill-set
    # graph partitioning — no need to precompute it here.
    def precompute_shared(services)
      t3 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      tw_incompat = TimewindowCompatibility.compute_incompatibilities(@vrp)
      log_duration('graph_timewindow_compatibility', t3)

      t4 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cap_incompat = CapacityCompatibility.compute_incompatibilities(@vrp)
      log_duration('graph_capacity_compatibility', t4)

      all_incompat = merge_nested_incompat(tw_incompat, cap_incompat)
      vehicle_skill_sets = @vrp.vehicles.map { |v| v.skills.first.to_a.map(&:to_s) }

      vrp_matrix = @vrp.matrices.find{ |m| m.id == @matrix_id }

      {
        all_incompat: all_incompat,
        vehicle_skill_sets: vehicle_skill_sets,
        vrp_time_matrix: vrp_matrix&.time,
        service_by_id: services.each_with_object({}) { |s, h| h[s.id] = s }
      }
    end

    # Builds a Models::Graph from a subset of services using pre-computed shared data.
    def build_for_services(services, shared, label: nil)
      t_build_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      log_prefix = label ? "graph[#{label}]" : 'graph'

      all_incompat = shared[:all_incompat]
      vrp_time_matrix = shared[:vrp_time_matrix]

      used_point_ids = services.map { |s| s.activity.point_id || s.activity.point&.id }.compact.uniq
      graph_points = @vrp.points.select { |p| used_point_ids.include?(p.id) }
      graph_points = services.map{ |s| s.activity.point }.compact.uniq(&:id) if graph_points.empty?

      point_by_index = graph_points.each_with_index.to_h { |p, i| [i, p] }
      services_by_point_id = {}
      point_id_to_service_ids = {}
      services.each do |s|
        pid = (s.activity.point_id || s.activity.point&.id).to_s
        (services_by_point_id[pid] ||= []) << s
        (point_id_to_service_ids[pid] ||= []) << s.id
      end

      delaunay_points = graph_points.map { |p| point_location_coords(p) }
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      delaunay_edges = DelaunayAdapter.compute_edges(delaunay_points)
      log_duration("#{log_prefix}_delaunay", t0)

      nodes = {}
      services.each do |s|
        activity = s.activity
        pt = activity.point
        next unless pt

        loc = pt.location
        pid = pt.id

        nodes[s.id] = {
          point_id: pid,
          point: { lat: loc&.lat, lon: loc&.lon },
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
      end

      # Expand Delaunay edges (point-level) to service-level compatible pairs
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
      edge_set = {}
      filtered_degree = Hash.new(0)

      delaunay_edges.each do |i, j|
        pid_a = point_by_index[i]&.id
        pid_b = point_by_index[j]&.id
        next unless pid_a && pid_b
        next if pid_a == pid_b

        added_for_pair = false

        (services_by_point_id[pid_a] || []).each do |s_a|
          (services_by_point_id[pid_b] || []).each do |s_b|
            next if all_incompat.dig(s_a.id, s_b.id)

            pair = [s_a.id, s_b.id].sort
            next if edge_set.key?(pair)

            edges << [s_a.id, s_b.id]
            edge_set[pair] = true
            added_for_pair = true
          end
        end

        next unless added_for_pair

        filtered_degree[pid_a] += 1
        filtered_degree[pid_b] += 1
      end

      # Intra-point edges: compatible co-located service pairs.
      # Requires vehicle-level feasibility (at least one vehicle covers both).
      # point_id_to_service_ids.each do |_pid, sids|
      #   next if sids.size < 2

      #   sids.each_with_index do |sid_a, idx_a|
      #     (idx_a + 1).upto(sids.size - 1) do |idx_b|
      #       sid_b = sids[idx_b]
      #       next if all_incompat.dig(sid_a, sid_b)
      #       next unless any_vehicle_covers_both?(service_by_id[sid_a], service_by_id[sid_b], vehicle_skill_sets)

      #       pair = [sid_a, sid_b].sort
      #       next if edge_set.key?(pair)

      #       edges << [sid_a, sid_b]
      #       edge_set[pair] = true
      #     end
      #   end
      # end

      repaired_nodes = {}
      original_degree.each do |pid, deg|
        next if deg <= (filtered_degree[pid] || 0)

        repaired_nodes[pid] = true
      end

      log_duration(
        "#{log_prefix}_edges_filter",
        t5,
        "delaunay=#{delaunay_edges.size} service_edges=#{edges.size} repaired_nodes=#{repaired_nodes.size}"
      )

      # K-NN: point-level computation, then expand to service-level
      t6 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      repaired_pids = repaired_nodes.keys
      all_pids = graph_points.map(&:id)
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
      point_knn_neighbors = KnnNeighborhood.compute_knn_points(
        repaired_pids, other_pids, knn_matrix, point_incompat, k: k_per_point
      )

      knn_added = 0
      knn_segments = []
      knn_edge_indices = []
      point_knn_neighbors.each do |pid_a, neighbor_pids|
        next unless repaired_nodes[pid_a]

        missing = (original_degree[pid_a] || 0) - (filtered_degree[pid_a] || 0)
        next if missing <= 0

        point_added = 0
        neighbor_pids.each do |pid_b|
          break if point_added >= missing

          first_edge_idx = nil
          (services_by_point_id[pid_a] || []).each do |s_a|
            (services_by_point_id[pid_b] || []).each do |s_b|
              next if all_incompat.dig(s_a.id, s_b.id)

              pair = [s_a.id, s_b.id].sort
              next if edge_set.key?(pair)

              edges << [s_a.id, s_b.id]
              edge_set[pair] = true
              knn_added += 1
              first_edge_idx ||= edges.size - 1
            end
          end

          next unless first_edge_idx

          point_added += 1
          loc_a = pid_to_point[pid_a]&.location
          loc_b = pid_to_point[pid_b]&.location
          if loc_a && loc_b
            knn_segments << [loc_a.lat.to_f, loc_a.lon.to_f, loc_b.lat.to_f, loc_b.lon.to_f]
            knn_edge_indices << first_edge_idx
          end
        end
      end

      service_knn_neighbors = {}
      point_knn_neighbors.each do |pid_a, neighbor_pids|
        sids_a = point_id_to_service_ids[pid_a] || []
        sids_a.each do |sid_a|
          neighbors_for_sid = []
          neighbor_pids.each do |pid_b|
            sids_b = point_id_to_service_ids[pid_b] || []
            sids_b.each do |sid_b|
              next if all_incompat.dig(sid_a, sid_b)

              neighbors_for_sid << sid_b
            end
          end
          service_knn_neighbors[sid_a] = neighbors_for_sid unless neighbors_for_sid.empty?
        end
      end

      add_knn_traces!(edges, knn_segments, knn_edge_indices) if knn_segments.any?

      knn_matrix_type = vrp_time_matrix ? 'square_in_memory' : "rectangular=#{repaired_pids.size}x#{other_pids.size}"
      log_duration("#{log_prefix}_knn", t6, "knn_added=#{knn_added} #{knn_matrix_type}")

      log_duration("#{log_prefix}_build", t_build_start)

      Models::Graph.new(
        nodes: nodes,
        edges: edges,
        incompatibilities: nested_incompat_to_pairs(all_incompat),
        knn_neighbors: service_knn_neighbors,
        metadata: {
          delaunay_built_at: Time.now.iso8601,
          matrix_id_used: @matrix_id,
          skill_label: label
        }
      )
    end

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

    # Returns true if at least one vehicle has the skills to serve both services.
    def any_vehicle_covers_both?(service_a, service_b, vehicle_skill_sets)
      return true unless service_a && service_b

      skills_a = service_a.skills.to_a.map(&:to_s)
      skills_b = service_b.skills.to_a.map(&:to_s)
      return true if skills_a.empty? && skills_b.empty?

      vehicle_skill_sets.any? { |v_skills|
        (skills_a.empty? || (skills_a - v_skills).empty?) &&
          (skills_b.empty? || (skills_b - v_skills).empty?)
      }
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
