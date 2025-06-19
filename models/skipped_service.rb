require './models/base'

module Models
  class SkippedService < Base
    field :service, default: nil
    field :reasons, default: []
  end
end
