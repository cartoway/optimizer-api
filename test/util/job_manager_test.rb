# Copyright © Cartoway, 2026
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

class JobManagerTest < Minitest::Test
  def test_status_options_omit_services_vrps_from_status_hash
    options = {
      'services_vrps' => 'HUGE_BLOB',
      'api_key' => 'demo',
      'checksum' => 'abc',
      'vrp_name' => 'toy'
    }

    slim = OptimizerWrapper::Job.status_options(options)

    refute slim.key?('services_vrps')
    assert_equal 'demo', slim['api_key']
    assert_equal 'toy', slim['vrp_name']

    uuid = nil
    Resque.stub(:enqueue_to, true) do
      uuid = OptimizerWrapper::Job.enqueue_to(
        'DEFAULT',
        OptimizerWrapper::Job,
        options
      )
    end

    status = Resque::Plugins::Status::Hash.get(uuid)
    refute status.options.key?('services_vrps'), 'status hash must not duplicate the VRP blob'
    assert_equal 'demo', status.options['api_key']
  ensure
    Resque::Plugins::Status::Hash.remove(uuid) if uuid
  end
end
