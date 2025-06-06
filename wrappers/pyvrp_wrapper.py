import json
import sys
import numpy as np
from pyvrp import Model, ProblemData, Client, Depot, VehicleType, ClientGroup, SolveParams, PenaltyParams
from pyvrp.stop import MaxRuntime

def _problem_data_from_dict(cls, data: dict):
    """
    Creates a :class:`~pyvrp._pyvrp.ProblemData` instance from a dictionary.
    """
    clients = [Client(**client) for client in data["clients"]]
    depots = [Depot(**depot) for depot in data["depots"]]
    vehicle_types = [VehicleType(**vt) for vt in data["vehicle_types"]]
    distance_matrices = [np.array(mat) for mat in data["distance_matrices"]]
    duration_matrices = [np.array(mat) for mat in data["duration_matrices"]]
    groups = [ClientGroup(**group) for group in data.get("groups", [])]
    return ProblemData(
        clients=clients,
        depots=depots,
        vehicle_types=vehicle_types,
        distance_matrices=distance_matrices,
        duration_matrices=duration_matrices,
        groups=groups,
    )

# Monkey-patch
setattr(ProblemData, "from_dict", classmethod(_problem_data_from_dict))

def main(input_path, output_path, timeout=None):
    # Load problem data from JSON
    with open(input_path, "r") as f:
        json_data = json.loads(f.read())

    data = ProblemData.from_dict(json_data)
    m = Model.from_data(data)
    # Solve the problem
    penalty_params = PenaltyParams(target_feasible=0.8)
    solve_params = SolveParams(penalty=penalty_params)
    result = m.solve(stop=MaxRuntime(int(timeout)), params=solve_params)

    best_solution = result.best
    solution = {
        "runtime": getattr(result, "run_time", None),
        "iterations": getattr(result, "num_iterations", None),
        "cost": result.cost() if result.cost() != np.inf else -1,
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
