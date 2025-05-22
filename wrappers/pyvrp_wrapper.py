import json
import sys

from pyvrp import Model, ProblemData
from pyvrp.stop import MaxRuntime

def main(input_path, output_path, timeout=None):
    # Load problem data from JSON
    with open(input_path, "r") as f:
        json_dict = json.load(f)

    data = ProblemData.from_json(json_dict)
    m = Model.from_data(data)
    # Solve the problem
    result = m.solve(stop=MaxRuntime(int(timeout)))

    best_solution = result.best
    solution = {
        "runtime": getattr(result, "run_time", None),
        "iterations": getattr(result, "num_iterations", None),
        "cost": result.cost(),
        "feasible": best_solution.is_feasible(),
        "complete": best_solution.is_complete(),
        "routes": [
            {
                "vehicle_type": route.vehicle_type(),
                "visits": route.visits(),
                "start_depot": route.start_depot(),
                "end_depot": route.end_depot(),
                "start_time": route.start_time(),
                "end_time": route.end_time()
            }
            for route in best_solution.routes()
        ]
    }

    with open(output_path, "w") as f:
        json.dump(solution, f, indent=2)

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python pyvrp_wrapper.py input.json output.json timeout")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
