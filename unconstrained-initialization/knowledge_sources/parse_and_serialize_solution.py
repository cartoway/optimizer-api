#base imports
from knowledge_sources.abstract_knowledge_source import AbstractKnowledgeSource
import logging as log
from pathlib import Path
from google.protobuf import text_format
log = log.getLogger(Path(__file__).stem)

#KS imports
import numpy
from sklearn.cluster import KMeans, AgglomerativeClustering, OPTICS, SpectralClustering, MiniBatchKMeans, DBSCAN
from fastvrpy.core.solutions import cvrptw

from google.protobuf.json_format import MessageToDict
import localsearch_result_pb2
import json



class ParseAndSerializeSolution(AbstractKnowledgeSource):
    """
   Parse and Serialize the founded solution
    """
    def verify(self):

        if self.blackboard.solution is None:
            raise AttributeError("Solution is None, not possible to parse and serialize the solution")

        if self.blackboard.output_file is None:
            raise AttributeError("Output file is None, not possible to parse and serialize the solution")


        return True

    def process(self):
        solution = self.blackboard.solution
        paths = numpy.asarray(solution.paths)
        result = localsearch_result_pb2.Result()
        for path_index,path in enumerate(paths):
            if len(set(path)) > 1 :
                route = result.routes.add()
                store = route.activities.add()
                store.id = "store"
                store.index = -1
                store.start_time = int(self.blackboard.solution.vehicle_starts[path_index])
                store.type = "start"
                for stop_index,stop in enumerate(path):
                    if stop != -1 and solution.is_break[stop] == 0:
                        activity = route.activities.add()
                        activity.id = self.blackboard.service_index_to_id[stop]
                        activity.index = stop
                        activity.start_time = int(self.blackboard.solution.starts[path_index, stop_index+1])
                        activity.type = "service"
                    elif stop != -1 and solution.is_break[stop] == 1:
                        rest = route.activities.add()
                        rest.type = "break"
                        rest.id = self.blackboard.service_index_to_id[stop]
                        rest.start_time = int(self.blackboard.solution.starts[path_index, stop_index+1])
                    else:
                        break
                store_return = route.activities.add()
                store_return.id = "store"
                store_return.index = -1
                store_return.start_time = int(self.blackboard.solution.vehicle_ends[path_index])
                store_return.type = "end"
                cost_details = route.cost_details
                cost_details.fixed = solution.vehicle_fixed_costs[path_index]
                cost_details.distance = solution.distances[path_index] * solution.cost_distance_multiplier[path_index]
                cost_details.time = solution.travel_times[path_index] * solution.cost_time_multiplier[path_index]

            else:
                route = result.routes.add()
                start_route = route.activities.add()
                start_route.type ="start"
                start_route.index = -1
                start_route.start_time = 0
                end_route = route.activities.add()
                end_route.type ="start"
                end_route.index = -1
                end_route.start_time = 0
        f = open(self.blackboard.output_file, "wb")
        f.write(result.SerializeToString())
        f.close()