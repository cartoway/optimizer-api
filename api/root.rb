# Copyright © Mapotempo, 2015
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

require './api/api_v01'

module Api
  class Root < Grape::API
    mount ApiV01

    # Omit VRP body from access logs (payloads are huge; dumps go to dump_vrp_dir when enabled)
    VRP_LOG_PARAM_FILTER = %w[
      vrp points vehicles services matrices shipments routes relations
      units rests zones subtours quantities capacities timewindows configuration
    ].freeze

    logger.formatter = GrapeLogging::Formatters::Default.new
    use GrapeLogging::Middleware::RequestLogger,
        logger: logger,
        include: [GrapeLogging::Loggers::FilterParameters.new(VRP_LOG_PARAM_FILTER)]

    format :json

    desc 'Ping hook. Responds by "pong".'
    get '/ping' do
      'pong'
    end
  end
end
