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
  class ServiceTest < IsolatedTest
    def test_skills
      service1 = { id: 'service_1' }
      service2 = { id: 'service_2' }

      s1 = Models::Service.create(service1)
      s2 = Models::Service.create(service2)

      refute_same s1.skills, s2.skills

      problem = { services: [service1, service2] }

      vrp = Models::Vrp.create(problem)

      refute_same vrp.services.first.skills,
                  vrp.services.last.skills

      Models.delete_all
      service1[:skills] = nil
      service2[:skills] = nil

      s1 = Models::Service.create(service1)
      s2 = Models::Service.create(service2)

      refute_same s1.skills, s2.skills

      problem = { services: [service1, service2] }

      vrp = Models::Vrp.create(problem)

      refute_same vrp.services.first.skills,
                  vrp.services.last.skills
    end
  end
end
