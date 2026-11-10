# Copyright © Cartoway, 2026
#
require './test/test_helper'

module Api
  module V01
    class GrapeThreadSafetyTest < Minitest::Test
      include Rack::Test::Methods

      def app
        ::Api::Root
      end

      # Happy path: concurrent nested array validation must not cross-contaminate
      # ParamsScope indices (fixed in Grape >= 3.2 via ParamScopeTracker).
      def test_concurrent_timewindow_validation_does_not_false_fail
        services =
          Array.new(50){ |i|
            {
              id: "s#{i}",
              activity: {
                point_id: 'p1',
                timewindows: [{ start: i, end: i + 100 }]
              }
            }
          }
        payload = {
          api_key: 'demo',
          vrp: {
            points: [{ id: 'p1', location: { lat: 1.0, lon: 2.0 } }],
            vehicles: [{ id: 'v1', router_mode: 'car', router_dimension: 'time' }],
            services: services,
            configuration: { resolution: { duration: 1 } }
          }
        }

        errors = Queue.new
        statuses = Queue.new
        threads =
          Array.new(8){
            Thread.new{
              # Each thread needs its own rack-test session
              session = Rack::Test::Session.new(Rack::MockSession.new(app))
              response = session.post('/0.1/vrp/validate', payload.to_json,
                                      { 'CONTENT_TYPE' => 'application/json' })
              statuses << response.status
              body = response.body.to_s
              if response.status != 201 ||
                 body.include?('at least one parameter must be provided') ||
                 body.match?(/activity\]\[\d+\]/)
                errors << "#{response.status}: #{body[0..300]}"
              end
            }
          }
        threads.each(&:join)

        assert_empty(Array.new(errors.size){ errors.pop })
        collected = Array.new(8){ statuses.pop }

        assert(collected.all?(201)) { collected.inspect }
      end
    end
  end
end
