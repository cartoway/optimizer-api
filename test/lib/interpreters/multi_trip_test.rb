require './test/test_helper'

class MultiTripInterpreterTest < Minitest::Test
  def test_class_presolve_delegates_to_instance
    service_vrp = Minitest::Mock.new
    job_id = 42

    multi_trip_instance = Minitest::Mock.new
    multi_trip_instance.expect(:presolve, :result, [service_vrp, job_id])

    Interpreters::MultiTrip.stub(:new, multi_trip_instance) do
      result = Interpreters::MultiTrip.presolve(service_vrp, job_id)
      assert_equal :result, result
    end

    multi_trip_instance.verify
  end
end
