module Interpreters
  class MultiTrip
    # Class-level presolve entry point used by orchestration
    # Delegates to the instance-level implementation to keep logic in one place.
    def self.presolve(service_vrp, job = nil, &)
      new.presolve(service_vrp, job, &)
    end

    def presolvable?(_service_vrp)
      # Disabled: PyVRP handles reloads natively. Re-enable VROOM seeding here later if needed.
      false
    end

    def presolve(service_vrp, _job = nil, &)
      return nil unless presolvable?(service_vrp)

      service_vrp.mark_interpreter!(:multi_trip)
      nil
    end
  end
end
