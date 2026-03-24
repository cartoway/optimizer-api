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
# Graph model for VRP: Delaunay triangulation, compatibilities, K-NN neighborhood.
# Nodes are keyed by service_id (one node per service). Each node carries point_id as back-reference.
# Edges are service-level pairs [service_id_a, service_id_b].
# knn_neighbors: service_id => [neighbor_service_id, ...].
# Plain value object (not ActiveHash).

module Models
  class Graph < Base
    field :id
    field :nodes, default: {}
    field :edges, default: []
    field :incompatibilities, default: []
    field :knn_neighbors, default: {}
    field :metadata, default: {}

    def to_hash
      {
        nodes: nodes || {},
        edges: edges || [],
        incompatibilities: incompatibilities || [],
        knn_neighbors: knn_neighbors || {},
        metadata: metadata || {}
      }
    end

    def incompatible?(service_id_a, service_id_b)
      pair = [service_id_a, service_id_b].sort
      (incompatibilities || []).any?{ |a, b| [a, b].sort == pair }
    end

    # Returns neighbor service_ids for the given service_id,
    # combining Delaunay edges and KNN-repair edges.
    def neighbors_for_service(service_id)
      adjacency[service_id] || []
    end

    # Backward-compatible lookup: collects all services at the given point_id
    # and returns the union of their KNN neighbors.
    def neighbors_for_point(point_id)
      sids = service_ids_for_point(point_id)
      return [] if sids.empty?

      result = []
      sids.each do |sid|
        result.concat(neighbors_for_service(sid))
      end
      result.uniq
    end

    # Returns service_ids whose node has the given point_id.
    def service_ids_for_point(point_id)
      @service_ids_by_point ||= build_service_ids_by_point
      @service_ids_by_point[point_id] || @service_ids_by_point[point_id.to_s] || []
    end

    def edge_set
      @edge_set ||= (edges || []).map{ |e| [[e[0], e[1]].sort, true] }.to_h
    end

    def connected?(id_a, id_b)
      edge_set.key?([id_a, id_b].sort)
    end

    # Returns connected service pairs within a set of service_ids.
    # Also accepts point_ids for backward compatibility (expanded to service_ids).
    # @param ids [Array<String>] service_ids or point_ids
    # @return [Array<[String, String]>] Pairs of connected IDs
    def tours_connectivity(ids)
      id_hash = ids.each_with_object({}) { |id, h| h[id] = true }
      edges.select{ |e| id_hash[e[0]] && id_hash[e[1]] }.map{ |e| [e[0], e[1]].sort }.uniq
    end

    # @param solution [Models::Solution]
    # @return [Hash] route_index => [[service_id_a, service_id_b], ...]
    def tours_connectivity_from_solution(solution)
      result = {}
      solution.routes.each_with_index do |route, idx|
        service_ids = route.stops.filter_map(&:service_id).compact
        result[idx] = tours_connectivity(service_ids)
      end
      result
    end

    def to_geojson
      require 'rgeo'
      require 'rgeo/geo_json'
      geo_factory = RGeo::Geographic.spherical_factory(srid: 4326)
      entity_factory = RGeo::GeoJSON::EntityFactory.instance
      features = []

      # Point feature per service node
      (nodes || {}).each do |service_id, data|
        pt = data[:point] || data['point']
        next unless pt

        lon = pt[:lon] || pt['lon']
        lat = pt[:lat] || pt['lat']
        next unless lon && lat

        point_geom = geo_factory.point(lon.to_f, lat.to_f)

        props = {
          service_id: service_id,
          point_id: data[:point_id] || data['point_id'],
          skills: data[:skills] || data['skills'],
          timewindows: data[:timewindows] || data['timewindows'],
          batch: data[:batch]
        }.delete_if{ |_k, v| v.nil? }

        features << entity_factory.feature(point_geom, service_id, props)
      end

      # LineStrings for each edge (format: [sid_a, sid_b] or [sid_a, sid_b, geometry])
      (edges || []).each do |e|
        a, b = e[0], e[1]
        geometry = e[2]
        node_a = (nodes || {})[a] || (nodes || {})[a.to_s]
        node_b = (nodes || {})[b] || (nodes || {})[b.to_s]
        next unless node_a && node_b

        pt_a = node_a[:point] || node_a['point']
        pt_b = node_b[:point] || node_b['point']
        next unless pt_a && pt_b

        pts =
          if geometry.is_a?(Array) && geometry.any?
            geometry.map{ |lon, lat| geo_factory.point(lon.to_f, lat.to_f) }
          else
            [
              geo_factory.point((pt_a[:lon] || pt_a['lon']).to_f, (pt_a[:lat] || pt_a['lat']).to_f),
              geo_factory.point((pt_b[:lon] || pt_b['lon']).to_f, (pt_b[:lat] || pt_b['lat']).to_f)
            ]
          end
        line_geom = geo_factory.line_string(pts)
        features << entity_factory.feature(line_geom, nil, { from: a, to: b, incompatible: incompatible?(a, b) })
      end

      collection = entity_factory.feature_collection(features)
      RGeo::GeoJSON.encode(collection)
    end

    private

    # Full adjacency list: Delaunay edges + KNN-repair edges, cached.
    def adjacency
      @adjacency ||=
        begin
          adj = Hash.new { |h, k| h[k] = [] }
          (edges || []).each do |e|
            adj[e[0]] << e[1]
            adj[e[1]] << e[0]
          end
          (knn_neighbors || {}).each do |sid, neighbors|
            neighbors.each do |nb|
              adj[sid] << nb unless adj[sid].include?(nb)
              adj[nb] << sid unless adj[nb].include?(sid)
            end
          end
          adj
        end
    end

    def build_service_ids_by_point
      result = Hash.new { |h, k| h[k] = [] }
      (nodes || {}).each do |service_id, data|
        pid = data[:point_id] || data['point_id']
        result[pid] << service_id if pid
      end
      result
    end
  end

  # Wraps multiple per-skill Graph instances and exposes a unified interface.
  # Duck-types with Graph for neighbors_for_service, knn_neighbors, nodes, edges, to_geojson.
  class MultiGraph
    attr_reader :graphs

    # @param graphs [Hash{String|nil => Models::Graph}] skill_key => graph
    def initialize(graphs:)
      @graphs = graphs || {}
    end

    def neighbors_for_service(service_id)
      result = []
      @graphs.each_value do |g|
        result.concat(g.neighbors_for_service(service_id))
      end
      result.uniq
    end

    # Returns neighbors only from graphs whose skill-set intersects with the
    # given vehicle skills. Nil-keyed graphs (no-skill) are always included.
    def neighbors_for_service_with_vehicle_skills(service_id, vehicle_skills)
      v_skills = vehicle_skills.map(&:to_s)
      result = []
      @graphs.each do |key, g|
        if key.nil?
          result.concat(g.neighbors_for_service(service_id))
        else
          graph_skills = key.split(',')
          result.concat(g.neighbors_for_service(service_id)) if (v_skills & graph_skills).any?
        end
      end
      result.uniq
    end

    def neighbors_for_point(point_id)
      result = []
      @graphs.each_value do |g|
        result.concat(g.neighbors_for_point(point_id))
      end
      result.uniq
    end

    def knn_neighbors
      @knn_neighbors ||=
        begin
          merged = {}
          @graphs.each_value do |g|
            (g.knn_neighbors || {}).each do |sid, neighbors|
              (merged[sid] ||= []).concat(neighbors)
            end
          end
          merged.each_value(&:uniq!)
          merged
        end
    end

    def nodes
      @nodes ||=
        begin
          merged = {}
          @graphs.each_value { |g| merged.merge!(g.nodes || {}) }
          merged
        end
    end

    def edges
      @edges ||=
        begin
          seen = {}
          result = []
          @graphs.each_value do |g|
            (g.edges || []).each do |e|
              pair = [e[0], e[1]].sort
              next if seen[pair]

              seen[pair] = true
              result << e
            end
          end
          result
        end
    end

    def edge_set
      @edge_set ||= edges.each_with_object({}) { |e, h| h[[e[0], e[1]].sort] = true }
    end

    def connected?(id_a, id_b)
      edge_set.key?([id_a, id_b].sort)
    end

    def incompatible?(service_id_a, service_id_b)
      @graphs.values.first&.incompatible?(service_id_a, service_id_b) || false
    end

    def service_ids_for_point(point_id)
      result = []
      @graphs.each_value { |g| result.concat(g.service_ids_for_point(point_id)) }
      result.uniq
    end

    def tours_connectivity(ids)
      id_hash = ids.each_with_object({}) { |id, h| h[id] = true }
      edges.select{ |e| id_hash[e[0]] && id_hash[e[1]] }.map{ |e| [e[0], e[1]].sort }.uniq
    end

    def tours_connectivity_from_solution(solution)
      result = {}
      solution.routes.each_with_index do |route, idx|
        service_ids = route.stops.filter_map(&:service_id).compact
        result[idx] = tours_connectivity(service_ids)
      end
      result
    end

    def incompatibilities
      @graphs.values.first&.incompatibilities || []
    end

    def metadata
      {
        skill_keys: @graphs.keys,
        graph_count: @graphs.size
      }
    end

    def to_geojson
      merged_graph = Models::Graph.new(
        nodes: nodes,
        edges: edges,
        incompatibilities: incompatibilities,
        knn_neighbors: knn_neighbors
      )
      merged_graph.to_geojson
    end

    def to_hash
      {
        graphs: @graphs.transform_values(&:to_hash),
        merged_nodes: nodes.size,
        merged_edges: edges.size
      }
    end
  end
end
