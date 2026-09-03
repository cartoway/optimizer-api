import json
import sys
import numpy as np
from pyvrp import (
    Activity,
    ActivityType,
    ProblemData,
    Client,
    Depot,
    Location,
    VehicleType,
    ClientGroup,
    SolveParams,
    PenaltyParams,
    solve,
    Solution,
    Route,
)
from pyvrp.search import (
    OPERATORS,
    NeighbourhoodParams,
    RelocateAlternative,
    RelocateWithDepot,
    RemoveAdjacentDepot,
    ReplaceGroup,
)
from pyvrp.stop import MaxRuntime

def _normalize_client_groups(data: dict):
    """
    Rebuild membership from Client.group
    """
    clients = data.get("clients") or []
    groups = data.get("groups") or []
    if not groups:
        return

    by_group = {}
    for idx, client in enumerate(clients):
        group_idx = client.get("group")
        if group_idx is None:
            continue
        by_group.setdefault(group_idx, []).append(idx)

    n_clients = len(clients)
    n_depots = len(data.get("depots") or [])
    for group_idx, group in enumerate(groups):
        members = by_group.get(group_idx)
        if members:
            group["clients"] = members
            continue
        listed = list(group.get("clients") or [])
        if any(idx >= n_clients for idx in listed) and n_depots:
            listed = [idx - n_depots for idx in listed]
        group["clients"] = listed
        for idx in listed:
            if 0 <= idx < n_clients:
                clients[idx]["group"] = group_idx

def _problem_data_from_dict(cls, data: dict):
    """
    Creates a :class:`~pyvrp._pyvrp.ProblemData` instance from a dictionary.
    """
    _normalize_client_groups(data)
    if data.get("locations"):
        locations = [_location_from_dict(loc) for loc in data["locations"]]
        clients = [Client(**_without(client, "x", "y")) for client in data["clients"]]
        depots = [Depot(**_without(depot, "x", "y")) for depot in data["depots"]]
    else:
        locations = []
        depots = []
        for depot in data["depots"]:
            kwargs, loc_idx = _entity_with_location(depot, locations)
            depots.append(Depot(location=loc_idx, **kwargs))
        clients = []
        for client in data["clients"]:
            kwargs, loc_idx = _entity_with_location(client, locations)
            clients.append(Client(location=loc_idx, **kwargs))

    vehicle_types = [VehicleType(**_drop_nones(vt)) for vt in data["vehicle_types"]]
    distance_matrices = [np.array(mat) for mat in data["distance_matrices"]]
    duration_matrices = [np.array(mat) for mat in data["duration_matrices"]]
    groups = [ClientGroup(**group) for group in data.get("groups", [])]
    return ProblemData(
        locations=locations,
        clients=clients,
        depots=depots,
        vehicle_types=vehicle_types,
        distance_matrices=distance_matrices,
        duration_matrices=duration_matrices,
        groups=groups,
    )

def _without(payload: dict, *keys):
    return {key: value for key, value in payload.items() if key not in keys}

def _location_from_dict(payload: dict):
    return Location(
        x=payload.get("x", 0),
        y=payload.get("y", 0),
        name=payload.get("name", ""),
    )

def _drop_nones(payload: dict):
    return {key: value for key, value in payload.items() if value is not None}

def _entity_with_location(payload: dict, locations: list):
    kwargs = dict(payload)
    kwargs.pop("x", None)
    kwargs.pop("y", None)
    if "location" in kwargs:
        loc_idx = kwargs.pop("location")
    else:
        loc_idx = len(locations)
        locations.append(_location_from_dict({"name": kwargs.get("name", "")}))
    return kwargs, loc_idx

def _activity_idx(activity):
    idx = activity.idx
    return idx() if callable(idx) else idx

def _activities_from_route_dict(route_dict: dict):
    """
    Build the inner activity list for Route(). Start and end depots are owned
    by VehicleType. Only clients and intermediate reload depots go here.
    """
    activities = []
    for item in route_dict.get("activities") or []:
        kind = str(item["type"]).upper()
        idx = item["idx"]
        if kind == "DEPOT":
            activities.append(Activity(ActivityType.DEPOT, idx))
        elif kind in ("CLIENT", "PICKUP", "DELIVERY"):
            activities.append(Activity(ActivityType.CLIENT, idx))
    return activities

def _route_from_dict(route_dict: dict, data: ProblemData):
    activities = _activities_from_route_dict(route_dict)
    if not activities:
        return None
    return Route(
        data,
        activities=activities,
        vehicle_type=route_dict.get("vehicle_type", 0),
    )

def _inner_route_activities(route):
    """
    Route iteration includes VehicleType start/end depots. optimizer-api
    already adds those from start_depot/end_depot; only clients and
    intermediate reload depots belong in the activity list.
    """
    activities = list(route)
    if activities and activities[0].is_depot():
        activities = activities[1:]
    if activities and activities[-1].is_depot():
        activities = activities[:-1]
    return activities

def _finite_int(value):
    if value is None:
        return None
    try:
        if np.isinf(value) or np.isnan(value):
            return None
    except TypeError:
        pass
    return int(value)

def _schedule_fields(activity):
    if not hasattr(activity, "start_time"):
        return {}
    start_time = _finite_int(activity.start_time)
    if start_time is None:
        return {}
    end_time = _finite_int(activity.end_time)
    if end_time is None:
        end_time = start_time
    return {
        "start_time": start_time,
        "end_time": end_time,
        "wait_duration": _finite_int(activity.wait_duration) or 0,
        "duration": _finite_int(activity.duration) or 0,
    }

def _activity_to_dict(activity):
    if activity.is_depot():
        kind = "depot"
    elif activity.is_client():
        kind = "client"
    else:
        kind = str(getattr(activity.type, "name", activity.type)).lower()
    payload = {"type": kind, "idx": _activity_idx(activity)}
    payload.update(_schedule_fields(activity))
    return payload

def _route_to_dict(route):
    activities = list(route)
    start_depot_activity = activities[0] if activities and activities[0].is_depot() else None
    end_depot_activity = activities[-1] if len(activities) > 1 and activities[-1].is_depot() else None
    return {
        "vehicle_type": route.vehicle_type(),
        "activities": [_activity_to_dict(activity) for activity in _inner_route_activities(route)],
        "start_depot": route.start_depot(),
        "end_depot": route.end_depot(),
        "start_time": _finite_int(route.start_time()),
        "end_time": _finite_int(route.end_time()),
        "start_schedule": _schedule_fields(start_depot_activity) or None,
        "end_schedule": _schedule_fields(end_depot_activity) or None,
    }

def _solution_from_dict(cls, json_data: dict, data: ProblemData):
    routes = []
    for route in json_data.get("routes", []):
        built = _route_from_dict(route, data)
        if built is not None:
            routes.append(built)
    if not routes:
        return None
    return Solution(
        data=data,
        routes=routes,
    )

# Monkey-patch
setattr(ProblemData, "from_dict", classmethod(_problem_data_from_dict))
setattr(Solution, "from_dict", classmethod(_solution_from_dict))

INITIAL_PENALTY = 10.0


class RoadPenaltyParams(PenaltyParams):
    """
    0.14 `midpoint_penalties` starts at (min+max)/2. Raising max_penalty
    therefore also raises the *initial* penalty, so the search saturates
    in a few updates (PenaltyBoundWarning at ~10s on C530). Keep a high
    cap but start near the historic HGS value.
    """

    def midpoint_penalties(self, data):
        start = INITIAL_PENALTY
        return ([start] * data.num_load_dimensions, start, start)


def granular_num_neighbours(n_clients):
    """Scale Vidal-style granular neighbourhood with instance size."""
    if n_clients >= 2000:
        return 150
    if n_clients >= 200:
        return 100
    return 50

def build_solve_params(n_clients):
    """
    ILS defaults plus a larger granular neighbourhood.

    PyVRP 0.14 dropped route operators (SwapStar / SwapRoutes). Intensification
    is the default OPERATORS set, which includes SWAP-style Relocate/Swap plus
    RelocateAlternative / ReplaceGroup (multi-TW) and RelocateWithDepot /
    RemoveAdjacentDepot (reload depots).

    Default max_penalty (1e5) saturates on large VRPTW (PenaltyBoundWarning)
    while the search is still infeasible. Raise the cap on medium+ instances,
    but start penalties at INITIAL_PENALTY — 0.14's midpoint is max/2.
    Stay well below 1e8: PyVRP warns that a too-large cap overflows native ints.
    """
    max_penalty = 1_000_000.0 if n_clients >= 200 else 100_000.0
    penalty_params = RoadPenaltyParams(
        target_feasible=0.5,
        max_penalty=max_penalty,
    )
    neighbourhood = NeighbourhoodParams(
        num_neighbours=granular_num_neighbours(n_clients),
        weight_wait_time=0.2,
    )
    required = {
        RelocateAlternative,
        ReplaceGroup,
        RelocateWithDepot,
        RemoveAdjacentDepot,
    }
    operators = list(OPERATORS)
    for operator in required:
        if operator not in operators:
            operators.append(operator)
    return SolveParams(
        penalty=penalty_params,
        neighbourhood=neighbourhood,
        operators=operators,
    )

def main(input_path, output_path, timeout=None):
    # Load problem data from JSON
    with open(input_path, "r") as f:
        json_data = json.loads(f.read())

    data = ProblemData.from_dict(json_data)
    try:
        initial_solution = Solution.from_dict(json_data, data)
    except Exception as exc:
        print(f"PyVRP ignoring initial solution: {exc}", flush=True)
        initial_solution = None
    if initial_solution is not None:
        print(f"PyVRP initial solution routes={len(initial_solution.routes())}", flush=True)

    n_clients = data.num_clients
    n_groups = data.num_groups
    solve_params = build_solve_params(n_clients)
    print(
        "PyVRP PenaltyParams "
        f"min_penalty={solve_params.penalty.min_penalty} "
        f"max_penalty={solve_params.penalty.max_penalty} "
        f"initial_penalty={INITIAL_PENALTY} "
        f"target_feasible={solve_params.penalty.target_feasible}",
        flush=True,
    )
    print(
        "PyVRP search "
        f"clients={n_clients} groups={n_groups} "
        f"num_neighbours={solve_params.neighbourhood.num_neighbours} "
        f"operators={[op.__name__ for op in solve_params.operators]}",
        flush=True,
    )

    solve_kwargs = {
        "stop": MaxRuntime(int(timeout)),
        "params": solve_params,
        "display": True,
    }
    if initial_solution is not None:
        solve_kwargs["initial_solution"] = initial_solution

    result = solve(data, **solve_kwargs)

    best_solution = result.best
    solution = {
        "runtime": getattr(result, "run_time", None),
        "iterations": getattr(result, "num_iterations", None),
        "cost": result.cost() if result.cost() != np.inf else -1,
        "feasible": best_solution.is_feasible(),
        "complete": best_solution.is_complete(),
        "routes": [_route_to_dict(route) for route in best_solution.routes()],
    }

    with open(output_path, "w") as f:
        json.dump(solution, f, indent=2)

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python pyvrp_wrapper.py input.json output.json timeout")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
