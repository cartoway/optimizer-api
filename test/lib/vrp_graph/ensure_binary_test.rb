# frozen_string_literal: true

require './test/test_helper'

module VrpGraph
  class EnsureBinaryTest < Minitest::Test
    def test_ensure_built_returns_true_when_binary_exists
      skip 'vrp_delaunay binary not built (rake ext:vrp_delaunay)' unless
        File.executable?(EnsureBinary::BINARY_PATH)

      assert EnsureBinary.ensure_built!, 'ensure_built! should return true when binary exists'
    end

    def test_cargo_available_or_skip
      skip 'cargo not in PATH' unless EnsureBinary.cargo_available?

      assert true
    end
  end
end
