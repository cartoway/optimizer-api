class SolverType
  ALL_SOLVERS = %i[demo ortools pyvrp vroom].freeze

  def self.type_cast(value)
    value = value.split(',') if value.is_a?(String)

    if value.is_a?(Array)
      to_return = []
      value.each{ |solver|
        unless ALL_SOLVERS.include?(solver.to_sym)
          raise ArgumentError.new("Invalid solver value: #{solver}")
        end

        to_return << solver.to_sym
      }

      to_return
    else
      raise ArgumentError.new('Invalid type for solver value')
    end
  end

  def self.possible_solvers
    ALL_SOLVERS.reject{ |solver| solver == :demo }.map(&:to_s)
  end
end
