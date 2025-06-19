require './models/base'

module Models
  class ResolutionContext < Base
    field :service, default: nil, type: Symbol
    field :job_id, default: nil

    field :split_level, default: nil
    field :split_denominators, default: nil
    field :split_sides, default: nil
    field :split_solve_data, default: {}

    field :dicho_level, default: 0
    field :dicho_denominators, default: [1]
    field :dicho_sides, default: [0]
    field :dicho_data, default: {}
    has_many :skipped_services, class_name: 'Models::SkippedService'
    belongs_to :vrp, class_name: 'Models::Vrp'

    # Migrate old hash format to ResolutionContext objects
    def self.migrate_from_hash(hash_data)
      if hash_data.is_a?(Hash)
        # Old format: { vrp: vrp, service: service, dicho_level: 0, ... }
        new(
          vrp: hash_data[:vrp],
          service: hash_data[:service]&.to_sym,
          split_level: hash_data[:split_level],
          split_denominators: hash_data[:split_denominators],
          split_sides: hash_data[:split_sides],
          dicho_level: hash_data[:dicho_level] || 0,
          dicho_denominators: hash_data[:dicho_denominators] || [1],
          dicho_sides: hash_data[:dicho_sides] || [0],
          job_id: hash_data[:job_id]
        )
      else
        # Already a ResolutionContext object
        hash_data
      end
    end

    # Migrate an array of hash data to ResolutionContext objects
    def self.migrate_array(array_data)
      return [] if array_data.nil?

      array_data.map { |item| migrate_from_hash(item) }
    end
  end
end
