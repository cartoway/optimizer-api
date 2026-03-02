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
# Ensures vrp_delaunay Rust binary is built at startup if missing.
# Used by server (puma) and workers (resque) so graph endpoint works without manual rake.

module VrpGraph
  module EnsureBinary
    BINARY_PATH = File.expand_path('../../exe/vrp_delaunay', __dir__)
    EXT_DIR = File.expand_path('../../ext/vrp_delaunay', __dir__)

    module_function

    # Builds vrp_delaunay if binary is missing. Idempotent.
    # Logs and returns false if cargo is unavailable or build fails.
    def ensure_built!
      return true if File.executable?(BINARY_PATH)

      return false unless cargo_available?

      build!
    end

    def cargo_available?
      system('which cargo > /dev/null 2>&1')
    end

    def build!
      Dir.chdir(EXT_DIR) do
        return false unless system('cargo build --release', out: $stdout, err: $stderr)

        bin = File.join(EXT_DIR, 'target/release/vrp_delaunay')
        return false unless File.executable?(bin)

        dest = File.expand_path('../../exe', __dir__)
        FileUtils.mkdir_p(dest)
        FileUtils.cp(bin, File.join(dest, 'vrp_delaunay'))
        true
      end
    rescue Errno::ENOENT
      false
    end
  end
end
