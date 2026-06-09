import json
import math
import sys
import numpy as np
from pyvrp import Model, ProblemData, Client, Depot, VehicleType, ClientGroup, SolveParams, PenaltyParams, solve, Solution, Route, Trip
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

def _route_from_dict(route_dict: dict, data: ProblemData):
    """
    Creates a :class:`~pyvrp._pyvrp.Route` instance from a dictionary.
    """
    trips = []
    for trip_dict in route_dict.get("visits", []):
        trip_kwargs = {
            "visits": trip_dict.get("visits", []),
            "vehicle_type": trip_dict.get("vehicle_type", 0),
            "start_depot": trip_dict.get("start_depot", 0),
        }
        if trip_dict.get("end_depot") is not None:
            trip_kwargs["end_depot"] = trip_dict["end_depot"]
        trip = Trip(data, **trip_kwargs)
        trips.append(trip)

    return Route(
        data,
        visits=trips,
        vehicle_type=route_dict.get("vehicle_type", 0)
    )

def _solution_from_dict(cls, json_data: dict, data: ProblemData):
    routes = [_route_from_dict(route, data) for route in json_data.get("routes", [])]
    if not routes:
        return None
    return Solution(
        data=data,
        routes=routes,
    )

# Monkey-patch
setattr(ProblemData, "from_dict", classmethod(_problem_data_from_dict))
setattr(Solution, "from_dict", classmethod(_solution_from_dict))

def main(input_path, output_path, timeout=None):
    # Load problem data from JSON
    with open(input_path, "r") as f:
        json_data = json.loads(f.read())

    data = ProblemData.from_dict(json_data)
    initial_solution = Solution.from_dict(json_data, data)
    # Solve the problem
    # ProblemData exposes clients as a method, not as a list attribute.
    clients = list(data.clients())
    # Closest power of two for the number of clients (rounded to nearest).
    num_clients = len(clients)
    closest_power_two_exponent = 0 if num_clients <= 0 else round(math.log(num_clients, 3))
    min_penalty = 10 ** (1 + closest_power_two_exponent)
    penalty_params = PenaltyParams(target_feasible=0.8, min_penalty=min_penalty, max_penalty=1e10)
    solve_params = SolveParams(penalty=penalty_params)

    result = solve(
        data,
        stop=MaxRuntime(int(timeout)),
        params=solve_params,
        display=True,
        initial_solution=initial_solution,
    )

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
                "trips": [
                    {
                        "visits": trip.visits(),
                        "start_depot": trip.start_depot(),
                        "end_depot": trip.end_depot(),
                        "release_time": trip.release_time()
                    }
                    for trip in route.trips()
                ],
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
