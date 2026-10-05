module Interpreters
  class MultiTrip
    # Class-level presolve entry point used by orchestration
    # Delegates to the instance-level implementation to keep logic in one place.
    def self.presolve(service_vrp, job = nil, &block)
      new.presolve(service_vrp, job, &block)
    end

    def presolvable?(_service_vrp)
      # Disabled: PyVRP handles reloads natively. Re-enable VROOM seeding here later if needed.
      false
    end

    def presolve(service_vrp, _job = nil, &_block)
      return nil unless presolvable?(service_vrp)

      service_vrp.mark_interpreter!(:multi_trip)
      nil
    end
  end
end
