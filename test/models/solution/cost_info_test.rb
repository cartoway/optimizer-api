# Copyright © Mapotempo, 2022
#
# This file is part of Mapotempo.
#
# Mapotempo is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Mapotempo is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Mapotempo. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#
require './test/test_helper'

module Models
  class SolutionTest
    class CostInfo < Minitest::Test
      include Rack::Test::Methods

      def test_cost_info_comparison
        cost_a = Models::Solution::CostInfo.create({})
        cost_b = Models::Solution::CostInfo.create({})
        assert_equal cost_a, cost_b

        cost_hash = Models::Solution::CostInfo.field_names.map{ |field|
          [field, 1]
        }.to_h
        cost_a = Models::Solution::CostInfo.create(cost_hash)
        refute_equal cost_a, cost_b
      end
    end
  end
end
