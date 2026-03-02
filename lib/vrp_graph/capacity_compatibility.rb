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
  # Checks capacity compatibility: two services at different points are incompatible
  # if no vehicle (that can serve both) has enough capacity to deliver both in one route.
  # Uses max capacity per unit across vehicles that are skill-compatible with both.
  # Pickup (collected) and delivery (delivered) are checked independently per unit.
  module CapacityCompatibility
    module_function

    # @param vrp [Models::Vrp]
    # @return [Hash] nested: incompat[service_id_a][service_id_b] = true (bidirectional)
    def compute_incompatibilities(vrp)
      services = vrp.services
      vehicles = vrp.vehicles

      # Precompute: service => [pickup_hash, delivery_hash] (avoids O(n^2) recomputation)
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pd_by_service = services.map{ |s| [s.id, pickup_delivery_per_unit(s)] }.to_h
      log_duration('capacity_precompute_pickup_delivery', t1)

      # Factor vehicles by config (skills.first + capacities); many vehicles share the same config
      t2 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      config_to_caps = {}
      config_keys_by_service = {}
      vehicles.each do |v|
        config_key = vehicle_config_key(v)
        config_to_caps[config_key] ||= vehicle_capacity_hash(v)
      end
      services.each do |s|
        config_keys_by_service[s.id] = config_to_caps.keys.select{ |ck| skills_match_config?(ck, s) }
      end
      log_duration('capacity_precompute_vehicle_configs', t2, "configs=#{config_to_caps.size} vehicles=#{vehicles.size}")

      # Indices of services that have quantities (capacity-relevant)
      services_with_qty = {}
      services.each_index do |i|
        p, d = pd_by_service[services[i].id]
        services_with_qty[i] = true if p.any? || d.any?
      end

      # Group service indices by point_id (for cross-point pairs only)
      point_to_indices = Hash.new{ |h, k| h[k] = [] }
      services.each_with_index do |s, i|
        pid = s.activity&.point_id || s.activity&.point&.id
        point_to_indices[pid] << i if pid
      end
      point_ids = point_to_indices.keys

      # Hash.new { |h, k| h[k] = {} } creates a new hash per key (Hash.new({}) would share one default)
      incompat = Hash.new { |h, k| h[k] = {} }
      pairs_checked = 0

      t4 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      point_ids.each_with_index do |pid_a, ia|
        ib = ia + 1
        while ib < point_ids.size
          pid_b = point_ids[ib]
          indices_a = point_to_indices[pid_a]
          indices_b = point_to_indices[pid_b]

          indices_a.each do |i|
            indices_b.each do |j|
              s1 = services[i]
              s2 = services[j]
              # Skip if both have no quantities (always compatible)
              next if !services_with_qty[i] && !services_with_qty[j]

              pairs_checked += 1
              next if capacity_compatible_fast?(s1, s2, config_keys_by_service, config_to_caps, pd_by_service)

              id_a = s1.id
              id_b = s2.id
              incompat[id_a][id_b] = true
              incompat[id_b][id_a] = true
            end
          end
          ib += 1
        end
      end
      log_duration('capacity_pair_checks', t4, pairs_checked)
      incompat
    end

    def capacity_compatible_fast?(s1, s2, config_keys_by_service, config_to_caps, pd_by_service)
      compatible_configs = (config_keys_by_service[s1.id] || []) & (config_keys_by_service[s2.id] || [])
      return true if compatible_configs.empty?

      p1, d1 = pd_by_service[s1.id]
      p2, d2 = pd_by_service[s2.id]

      compatible_configs.any? do |config_key|
        max_caps = config_to_caps[config_key]
        next true if max_caps.nil? || max_caps.empty?

        max_caps.all? do |unit_id, limit|
          pickup_total = (p1[unit_id] || 0) + (p2[unit_id] || 0)
          delivery_total = (d1[unit_id] || 0) + (d2[unit_id] || 0)
          pickup_total <= limit && delivery_total <= limit
        end
      end
    end

    # Config key = [skills, capacities] for grouping vehicles with same config
    def vehicle_config_key(vehicle)
      skills = (vehicle.skills.first || []).to_a.map(&:to_s).sort
      caps = vehicle_capacity_hash(vehicle).sort
      [skills, caps]
    end

    # Service is incompatible with a vehicle config if not all its skills are covered by the config.
    def skills_match_config?(config_key, service)
      return true if service.skills.nil? || service.skills.empty?

      config_skills = config_key[0] || []
      service_skills = service.skills.to_a.map(&:to_s)
      (service_skills - config_skills).size == service_skills.size
    end

    def vehicle_capacity_hash(vehicle)
      h = {}
      vehicle.capacities.each do |cap|
        next if cap.unit_id.nil?
        next if cap.overload_multiplier&.positive?

        limit = cap.limit
        next if limit.nil?

        h[cap.unit_id] = [h[cap.unit_id], limit].compact.max
      end
      h
    end

    def merge_max_capacities(hashes)
      return {} if hashes.empty?

      result = hashes.first.dup
      hashes[1..].each do |h|
        h.each do |uid, lim|
          result[uid] = [result[uid], lim].compact.max
        end
      end
      result
    end

    # Returns [pickup_hash, delivery_hash] per unit.
    # Pickup = units collected; delivery = units delivered.
    # Convention: value < 0 => delivery, value > 0 => pickup (matches Vroom/PyVRP).
    def pickup_delivery_per_unit(service)
      pickup = {}
      delivery = {}
      (service.quantities || []).each do |q|
        next if q.empty?
        next if q.unit_id.nil?

        uid = q.unit_id
        pickup[uid] = (pickup[uid] || 0) + q.pickup if q.pickup
        delivery[uid] = (delivery[uid] || 0) + q.delivery if q.delivery
        next if (q.value || 0).zero?

        if (q.value || 0).negative?
          delivery[uid] = (delivery[uid] || 0) + q.value.abs
        else
          pickup[uid] = (pickup[uid] || 0) + q.value
        end
      end
      [pickup, delivery]
    end

    def log_duration(label, start_time, extra = nil)
      return unless defined?(OptimizerLogger)

      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)
      msg = "VrpGraph #{label}: #{elapsed_ms}ms"
      msg += " (pairs=#{extra})" if extra
      OptimizerLogger.log(msg, level: :info)
    end
  end
end
