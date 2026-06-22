# Copyright © Mapotempo, 2026
require './test/test_helper'

class TestHelperMatrixDumpTest < Minitest::Test
  def test_retrocompatible_matrix_dump_options_matches_current_vehicle_defaults
    legacy_options = {
      traffic: false,
      departure: nil,
      speed_multiplier: 1,
      area: [],
      speed_multiplier_area: [],
      track: true,
      motorway: true,
      toll: true,
      trailers: nil,
      weight: nil,
      weight_per_axle: nil,
      height: nil,
      width: nil,
      length: nil,
      hazardous_goods: nil,
      max_walk_distance: 750,
      approach: nil,
      snap: nil,
      strict_restriction: false
    }
    vehicle_options = Models::Vehicle.new(id: 'vehicle_0').router_options

    assert_equal TestHelper.retrocompatible_matrix_dump_options(legacy_options),
                 TestHelper.retrocompatible_matrix_dump_options(vehicle_options)
  end

  def test_matrices_required_finds_legacy_dump_entry
    return unless File.file?('test/fixtures/geometry_polyline.dump')

    dumped_data = Oj.load(Zlib.inflate(File.read('test/fixtures/geometry_polyline.dump')))
    legacy_options = dumped_data.first[:options]
    current_options = Models::Vehicle.new(id: 'vehicle_0', router_mode: :car).router_options

    assert_equal TestHelper.retrocompatible_matrix_dump_options(legacy_options),
                 TestHelper.retrocompatible_matrix_dump_options(current_options)
  end
end
