# frozen_string_literal: true

require './test/test_helper'

module VrpGraph
  class CapacityCompatibilityTest < Minitest::Test
    # VRP with 2 services at different points, quantities 2 each, vehicle capacity 5
    # Sum 4 <= 5 => compatible
    def test_pair_compatible_when_sum_within_max_capacity
      vrp = TestHelper.create(
        units: [{ id: 'kg' }],
        matrices: [{
          id: 'm1',
          time: [[0, 10, 10], [10, 0, 10], [10, 10, 0]]
        }],
        points: [
          { id: 'p0', matrix_index: 0, location: { lat: 45.0, lon: 5.0 } },
          { id: 'p1', matrix_index: 1, location: { lat: 45.01, lon: 5.01 } },
          { id: 'p2', matrix_index: 2, location: { lat: 45.02, lon: 5.02 } }
        ],
        vehicles: [{
          id: 'v1',
          matrix_id: 'm1',
          start_point_id: 'p0',
          capacities: [{ unit_id: 'kg', limit: 5 }]
        }],
        services: [
          { id: 's1', visits_number: 1, activity: { point_id: 'p1' }, quantities: [{ unit_id: 'kg', value: 2 }] },
          { id: 's2', visits_number: 1, activity: { point_id: 'p2' }, quantities: [{ unit_id: 'kg', value: 2 }] }
        ],
        configuration: { resolution: { duration: 100 }, restitution: { intermediate_solutions: false } }
      )

      incompat = CapacityCompatibility.compute_incompatibilities(vrp)
      refute incompat.dig('s1', 's2'), "s1+s2=4 <= 5 should be compatible, got #{incompat.inspect}"
    end

    # VRP with 2 services at different points, quantities 3 each, vehicle capacity 5
    # Sum 6 > 5 => incompatible
    def test_pair_incompatible_when_sum_exceeds_max_capacity
      vrp = TestHelper.create(
        units: [{ id: 'kg' }],
        matrices: [{
          id: 'm1',
          time: [[0, 10, 10], [10, 0, 10], [10, 10, 0]]
        }],
        points: [
          { id: 'p0', matrix_index: 0, location: { lat: 45.0, lon: 5.0 } },
          { id: 'p1', matrix_index: 1, location: { lat: 45.01, lon: 5.01 } },
          { id: 'p2', matrix_index: 2, location: { lat: 45.02, lon: 5.02 } }
        ],
        vehicles: [{
          id: 'v1',
          matrix_id: 'm1',
          start_point_id: 'p0',
          capacities: [{ unit_id: 'kg', limit: 5 }]
        }],
        services: [
          { id: 's1', visits_number: 1, activity: { point_id: 'p1' }, quantities: [{ unit_id: 'kg', value: 3 }] },
          { id: 's2', visits_number: 1, activity: { point_id: 'p2' }, quantities: [{ unit_id: 'kg', value: 3 }] }
        ],
        configuration: { resolution: { duration: 100 }, restitution: { intermediate_solutions: false } }
      )

      incompat = CapacityCompatibility.compute_incompatibilities(vrp)
      assert incompat.dig('s1', 's2'), "s1+s2=6 > 5 should be incompatible, got #{incompat.inspect}"
    end

    # Max capacity across vehicles: v1 cap 3, v2 cap 6 => max 6. s1(2)+s2(3)=5 <= 6
    def test_uses_max_capacity_across_vehicles
      vrp = TestHelper.create(
        units: [{ id: 'kg' }],
        matrices: [{
          id: 'm1',
          time: [[0, 10, 10], [10, 0, 10], [10, 10, 0]]
        }],
        points: [
          { id: 'p0', matrix_index: 0, location: { lat: 45.0, lon: 5.0 } },
          { id: 'p1', matrix_index: 1, location: { lat: 45.01, lon: 5.01 } },
          { id: 'p2', matrix_index: 2, location: { lat: 45.02, lon: 5.02 } }
        ],
        vehicles: [
          { id: 'v1', matrix_id: 'm1', start_point_id: 'p0', capacities: [{ unit_id: 'kg', limit: 3 }] },
          { id: 'v2', matrix_id: 'm1', start_point_id: 'p0', capacities: [{ unit_id: 'kg', limit: 6 }] }
        ],
        services: [
          { id: 's1', visits_number: 1, activity: { point_id: 'p1' }, quantities: [{ unit_id: 'kg', value: 2 }] },
          { id: 's2', visits_number: 1, activity: { point_id: 'p2' }, quantities: [{ unit_id: 'kg', value: 3 }] }
        ],
        configuration: { resolution: { duration: 100 }, restitution: { intermediate_solutions: false } }
      )

      incompat = CapacityCompatibility.compute_incompatibilities(vrp)
      refute incompat.dig('s1', 's2'), "max cap 6, s1+s2=5 => compatible"
    end

    # Pickup and delivery checked independently: s1 delivery 4, s2 pickup 3 => compatible (both <= 5)
    def test_pickup_and_delivery_checked_independently
      vrp = TestHelper.create(
        units: [{ id: 'kg' }],
        matrices: [{
          id: 'm1',
          time: [[0, 10, 10], [10, 0, 10], [10, 10, 0]]
        }],
        points: [
          { id: 'p0', matrix_index: 0, location: { lat: 45.0, lon: 5.0 } },
          { id: 'p1', matrix_index: 1, location: { lat: 45.01, lon: 5.01 } },
          { id: 'p2', matrix_index: 2, location: { lat: 45.02, lon: 5.02 } }
        ],
        vehicles: [{
          id: 'v1',
          matrix_id: 'm1',
          start_point_id: 'p0',
          capacities: [{ unit_id: 'kg', limit: 5 }]
        }],
        services: [
          { id: 's1', visits_number: 1, activity: { point_id: 'p1' }, quantities: [{ unit_id: 'kg', delivery: 4 }] },
          { id: 's2', visits_number: 1, activity: { point_id: 'p2' }, quantities: [{ unit_id: 'kg', pickup: 3 }] }
        ],
        configuration: { resolution: { duration: 100 }, restitution: { intermediate_solutions: false } }
      )

      incompat = CapacityCompatibility.compute_incompatibilities(vrp)
      refute incompat.dig('s1', 's2'), "delivery 4 + pickup 3, checked independently => compatible (both <= 5)"
    end

    # Two deliveries 4+3=7 > 5 => incompatible
    def test_two_deliveries_exceeding_capacity_incompatible
      vrp = TestHelper.create(
        units: [{ id: 'kg' }],
        matrices: [{
          id: 'm1',
          time: [[0, 10, 10], [10, 0, 10], [10, 10, 0]]
        }],
        points: [
          { id: 'p0', matrix_index: 0, location: { lat: 45.0, lon: 5.0 } },
          { id: 'p1', matrix_index: 1, location: { lat: 45.01, lon: 5.01 } },
          { id: 'p2', matrix_index: 2, location: { lat: 45.02, lon: 5.02 } }
        ],
        vehicles: [{
          id: 'v1',
          matrix_id: 'm1',
          start_point_id: 'p0',
          capacities: [{ unit_id: 'kg', limit: 5 }]
        }],
        services: [
          { id: 's1', visits_number: 1, activity: { point_id: 'p1' }, quantities: [{ unit_id: 'kg', delivery: 4 }] },
          { id: 's2', visits_number: 1, activity: { point_id: 'p2' }, quantities: [{ unit_id: 'kg', delivery: 3 }] }
        ],
        configuration: { resolution: { duration: 100 }, restitution: { intermediate_solutions: false } }
      )

      incompat = CapacityCompatibility.compute_incompatibilities(vrp)
      assert incompat.dig('s1', 's2'), "delivery 4+3=7 > 5 => incompatible"
    end

    # Same point => skip (not checked by capacity, different-points only)
    def test_skips_services_at_same_point
      vrp = TestHelper.create(
        units: [{ id: 'kg' }],
        matrices: [{
          id: 'm1',
          time: [[0, 10], [10, 0]]
        }],
        points: [
          { id: 'p0', matrix_index: 0, location: { lat: 45.0, lon: 5.0 } },
          { id: 'p1', matrix_index: 1, location: { lat: 45.01, lon: 5.01 } }
        ],
        vehicles: [{
          id: 'v1',
          matrix_id: 'm1',
          start_point_id: 'p0',
          capacities: [{ unit_id: 'kg', limit: 2 }]
        }],
        services: [
          { id: 's1', visits_number: 1, activity: { point_id: 'p1' }, quantities: [{ unit_id: 'kg', value: 2 }] },
          { id: 's2', visits_number: 1, activity: { point_id: 'p1' }, quantities: [{ unit_id: 'kg', value: 2 }] }
        ],
        configuration: { resolution: { duration: 100 }, restitution: { intermediate_solutions: false } }
      )

      incompat = CapacityCompatibility.compute_incompatibilities(vrp)
      refute incompat.dig('s1', 's2'), "same point => not checked, no capacity incompat added"
    end
  end
end
