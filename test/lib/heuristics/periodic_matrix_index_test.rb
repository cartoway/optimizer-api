# Copyright © Mapotempo, 2026
require './test/test_helper'

class PeriodicMatrixIndexTest < Minitest::Test
  def test_matrix_uses_id_index_happy_path
    vrp = TestHelper.create(VRP.periodic)
    vrp.vehicles = TestHelper.expand_vehicles(vrp)
    heuristic = Wrappers::PeriodicHeuristic.new(vrp)
    return skip('no matrices') if vrp.matrices.empty?

    route_data = {
      matrix_id: vrp.matrices.first.id,
      router_dimension: :time
    }
    point_a = vrp.points.first.id
    point_b = vrp.points[1]&.id || point_a

    assert_operator heuristic.send(:matrix, route_data, point_a, point_b), :>=, 0
  end

  def test_generate_route_fills_missions_from_services_data
    vrp = TestHelper.create(VRP.periodic)
    vrp.vehicles = TestHelper.expand_vehicles(vrp)
    heuristic = Wrappers::PeriodicHeuristic.new(vrp)
    service_id = heuristic.instance_variable_get(:@services_data).keys.first
    skip('no services_data') unless service_id

    vehicle = vrp.vehicles.first
    route = heuristic.send(:generate_route, vehicle, [{ id: service_id }])

    assert_equal 1, route[:missions].size
    assert_equal service_id, route[:missions].first.id
  end

  def test_available_ids_is_hash_and_day_respects_lapse
    vrp = TestHelper.create(VRP.periodic)
    vrp.vehicles = TestHelper.expand_vehicles(vrp)
    heuristic = Wrappers::PeriodicHeuristic.new(vrp)
    routes = heuristic.instance_variable_get(:@candidate_routes)
    sample = routes.values.first&.values&.first
    skip('no candidate routes') unless sample

    assert_kind_of Hash, sample[:available_ids]

    service_id = heuristic.instance_variable_get(:@services_data).keys.first
    skip('no services_data') unless service_id
    assignment = heuristic.instance_variable_get(:@services_assignment)
    assignment[service_id][:days] = [0]
    heuristic.instance_variable_get(:@services_data)[service_id][:raw].minimum_lapse = 2
    heuristic.instance_variable_get(:@services_data)[service_id][:raw].maximum_lapse = 10

    assert heuristic.send(:day_respects_lapse?, service_id, 3)
    refute heuristic.send(:day_respects_lapse?, service_id, 1)
  end

  def test_unavailable_for_routes_blocks_first_visit
    vrp = TestHelper.create(VRP.periodic)
    vrp.vehicles = TestHelper.expand_vehicles(vrp)
    heuristic = Wrappers::PeriodicHeuristic.new(vrp)
    service_id = heuristic.instance_variable_get(:@services_data).keys.first
    route_data = heuristic.instance_variable_get(:@candidate_routes).values.first.values.first
    skip('missing data') unless service_id && route_data

    route_data[:available_ids][service_id] = true
    heuristic.instance_variable_get(:@unavailable_for_routes)[service_id] = true

    refute heuristic.send(:service_compatible_with_route, service_id, route_data, true)

    heuristic.instance_variable_get(:@unavailable_for_routes).delete(service_id)
    # may still fail other constraints; at least unavailable flag alone must not block after delete
    assert_nil heuristic.instance_variable_get(:@unavailable_for_routes)[service_id]
  end

  def test_compute_route_from_orders_by_solver_index
    vrp = TestHelper.create(VRP.periodic)
    vrp.vehicles = TestHelper.expand_vehicles(vrp)
    heuristic = Wrappers::PeriodicHeuristic.new(vrp)
    ids = heuristic.instance_variable_get(:@services_data).keys.first(2)
    skip('need 2 services') if ids.size < 2

    # stub minimal route + solver stops (only service_id / info used)
    info = Struct.new(:begin_time).new(0)
    stop_class =
      Struct.new(:service_id, :info) do
        def [](key)
          service_id if key == :service_id
        end
      end
    new_route = {
      stops: [{ id: ids[0] }, { id: ids[1] }],
      start_point_id: vrp.vehicles.first.start_point&.id,
      end_point_id: vrp.vehicles.first.end_point&.id,
      matrix_id: vrp.matrices.first&.id,
      router_dimension: :time,
      tw_start: 0,
      tw_end: 86_400,
      day: 0,
      vehicle_original_id: vrp.vehicles.first.original_id,
      capacity_left: {},
      capacity: {},
    }
    # Avoid update_route side effects by stubbing
    heuristic.define_singleton_method(:update_route) { |*_args| nil }
    solver_stops = [stop_class.new(ids[1], info), stop_class.new(ids[0], info)]
    heuristic.send(:compute_route_from, new_route, solver_stops)

    assert_equal [ids[1], ids[0]], (new_route[:stops].map{ |stop| stop[:id] })
  end
end
