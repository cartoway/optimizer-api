# Copyright © Mapotempo, 2026
require './test/test_helper'

class ZoneTest < Minitest::Test
  def test_inside_polygon_happy_path
    skip 'rgeo without GEOS CAPI (install libgeos-dev + rebuild rgeo)' unless RGeo::Geos.capi_supported?

    zone = Models::Zone.create(
      id: 'zone_inside',
      polygon: {
        type: 'Polygon',
        coordinates: [[[0.5, 48.5], [1.5, 48.5], [1.5, 49.5], [0.5, 49.5], [0.5, 48.5]]]
      }
    )

    assert zone.inside(49, 1)
    refute zone.inside(50, 3)
  end
end
