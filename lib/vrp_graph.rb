# frozen_string_literal: true

# Copyright © Cartoway, 2026
#
# This file is part of Cartoway Optimizer.
#
# Cartoway Planner is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Cartoway Optimizer is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Cartoway Optimizer. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#
# VRP Graph: Delaunay triangulation (Spade), compatibility checks, K-NN, GeoJSON export, batch assignment.
#
# Requires vrp_delaunay binary. Build with: rake ext:vrp_delaunay

require_relative 'vrp_graph/version'
require_relative 'vrp_graph/delaunay_adapter'
require_relative 'vrp_graph/skills_compatibility'
require_relative 'vrp_graph/timewindow_compatibility'
require_relative 'vrp_graph/knn_neighborhood'
require_relative 'vrp_graph/graph_builder'
require_relative 'vrp_graph/batch_assigner'
