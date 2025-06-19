require './models/base'

module Models
  class ResolutionContext < Base
    field :service, default: nil
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
  end
end
