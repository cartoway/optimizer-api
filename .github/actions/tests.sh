#!/usr/bin/env bash

docker compose exec api rake test TESTOPTS="${TESTOPTS}" ${OPTIONS}
