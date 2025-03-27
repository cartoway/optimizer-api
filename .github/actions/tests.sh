#!/usr/bin/env bash

CONTAINER=${PROJECT}_api.1.$(docker service ps -f "name=${PROJECT}_api.1" ${PROJECT}_api -q --no-trunc | head -n1)

echo $REDIS_RESQUE_HOST
nc -zv redis-resque 6379

docker exec -i ${CONTAINER} rake test TESTOPTS="${TESTOPTS}" ${OPTIONS}

exit_code=$?
if [ $exit_code -ne 0 ]; then
    echo "Tests failed with exit code: $exit_code"
    docker service logs ${PROJECT}_api
fi
exit $exit_code
