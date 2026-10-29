# Copyright © Mapotempo, 2026
require './test/test_helper'

class RouteTest < Minitest::Test
  def test_mission_ids_assignment_write_through
    vrp = TestHelper.create(VRP.basic)
    route = Models::Route.create(
      vehicle: vrp.vehicles.first,
      mission_ids: %w[service_1 service_2]
    )

    assert_equal %w[service_1 service_2], route.mission_ids

    route.mission_ids = %w[service_3]
    assert_equal %w[service_3], route.mission_ids
    assert_equal 1, route.missions.size
  end

  def test_add_unassigned_removes_missions_from_routes
    problem = VRP.basic
    problem[:routes] = [{
      vehicle_id: problem[:vehicles].first[:id],
      mission_ids: problem[:services].map{ |s| s[:id] }
    }]
    vrp = TestHelper.create(problem)
    demo = OptimizerWrapper.config[:services][:demo]

    demo.add_unassigned({}, vrp, vrp.services.first, 'test')

    assert_equal %w[service_2 service_3], vrp.routes.first.mission_ids
  end
end
