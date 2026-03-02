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
# Nodes and edges are point-based (point_id). knn_neighbors: point_id => [neighbor_point_id, ...].
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

    # K-NN is point-based: returns neighbor point_ids for the given point_id.
    def neighbors_for_point(point_id)
      (knn_neighbors || {})[point_id] || []
    end

    def edge_set
      @edge_set ||= (edges || []).map{ |e| [[e[0], e[1]].sort, true] }.to_h
    end

    def connected?(point_id_a, point_id_b)
      edge_set.key?([point_id_a, point_id_b].sort)
    end

    # Returns connected point pairs within a route's point set.
    # @param point_ids [Array<String, Integer>] Point IDs in the route
    # @return [Array<[String, String]>] Pairs of connected point IDs
    def tours_connectivity(point_ids)
      ids = point_ids.to_set
      edges.select{ |e| ids.include?(e[0]) && ids.include?(e[1]) }.map{ |e| [e[0], e[1]].sort }.uniq
    end

    # @param solution [Models::Solution]
    # @return [Hash] route_index => [[point_id_a, point_id_b], ...]
    def tours_connectivity_from_solution(solution)
      result = {}
      solution.routes.each_with_index do |route, idx|
        point_ids = route.stops.filter_map{ |s| s.activity&.point_id }.compact
        result[idx] = tours_connectivity(point_ids)
      end
      result
    end

    def to_geojson
      require 'rgeo'
      require 'rgeo/geo_json'
      geo_factory = RGeo::Geographic.spherical_factory(srid: 4326)
      entity_factory = RGeo::GeoJSON::EntityFactory.instance
      features = []

      # Points for each node (point-level); each node aggregates its services and constraints
      nodes.each do |point_id, data|
        pt = data[:point] || data['point']
        next unless pt

        lon = pt[:lon] || pt['lon']
        lat = pt[:lat] || pt['lat']
        next unless lon && lat

        point_geom = geo_factory.point(lon.to_f, lat.to_f)

        props = {
          point_id: point_id,
          services: data[:services] || data['services']
        }.delete_if{ |_k, v| v.nil? }

        features << entity_factory.feature(point_geom, point_id, props)
      end

      # LineStrings for each edge (format: [a, b] or [a, b, geometry])
      edges.each do |e|
        a, b = e[0], e[1]
        geometry = e[2]
        node_a = nodes[a] || nodes[a.to_s]
        node_b = nodes[b] || nodes[b.to_s]
        next unless node_a && node_b

        pt_a = node_a[:point] || node_a['point']
        pt_b = node_b[:point] || node_b['point']
        next unless pt_a && pt_b

        pts =
          if geometry.is_a?(Array) && geometry.any?
            # geometry from router: [[lon,lat], [lon,lat], ...]
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
  end
end
