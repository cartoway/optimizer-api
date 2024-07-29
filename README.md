# Optimizer API

Run an optimizer REST API depending of many constraints for a Vehicle Routing Problem (VRP).

This project use some solver engines:
* [Vroom v1.12.0](https://github.com/VROOM-Project/vroom/releases/tag/v1.12.0)
* [Optimizer-ortools v1.17.1](https://github.com/cartoroute/optimizer-ortools) & [OR-Tools v7.8](https://github.com/google/or-tools/releases/tag/v7.8) (use the version corresponding to your system operator, not source code).

## API

The API is defined in Swagger format at
http://localhost:1791/0.1/swagger_doc
and can be tested with Swagger-UI
https://petstore.swagger.io/?url=http://localhost:1791/0.1/swagger_doc

```
curl -X POST --header "Content-Type:application/json" --data '{"vrp":{"vehicles":[]}}' http://localhost:1791/0.1/vrp/submit.json?api_key=demo
```

Moreover, the concepts used are described in the [docs](docs/Home.md) folder.

## Docker

Optimizer API is build upon `optimizer-ortools` docker image. Build it first.
https://github.com/cartoroute/optimizer-ortools.git

Copy and adjust environments files.
```bash
cp ./config/environments/production.rb ./docker/
```

Create a `.env` from `.env.template`, and adapt if required.

Build docker images
```
docker compose build
```

Launch containers
```
docker compose up -d
```

## Without Docker
### On Ubuntu
```
sudo apt install libssl-dev libyaml-dev
```
Depending on the Ubuntu version, libssl 1.0 may not be available. Then the following may fix the issue.

```
sudo apt update
sudo apt install libssl1.0-dev
sudo apt install ruby-full
sudo apt install redis-server
sudo apt install libgeos-dev libgeos-3.7.1
sudo apt install libicu-dev
sudo systemctl enable redis-server.service
```

### On Mac OS
```
brew install redis
brew install geos
```

### Build
```
gem install bundler
bundle install
```

Note : when updating OR-Tools you should to recompile optimizer-ortools.

By default, Optimizer-API and the related projects are supposed to be in parallel folders as follows:

![Project folders](/public/images/folders.png?raw=true)

We recommend to use a symbolic link to point the OR-Tools asset.
```
  ln -s or-tools_Debian-10-64bit_v7.8.7959 or-tools
```

### Run
```
bundle exec rackup [-p 1791]
```

And in production mode:
```
APP_ENV=production bundle exec rackup [-p 1791]
```

Start Redis and then start the worker
```
APP_ENV=production COUNT=5 QUEUE=* bundle exec rake resque:workers
```

## Tests

Run tests:
```
APP_ENV=test bundle exec rake test
```

If you want to get information about how long each test lasts:
```
TIME=true HTML=true APP_ENV=test bundle exec rake test
```
This generates a report with test times. You can find the report in optimizer-api/test/html_reports folder.


If you want to run a specific test file (let's say real_cases_periodic_test.rb file only):
```
APP_ENV=test bundle exec rake test TEST=test/real_cases_periodic_test.rb
```
If you want to run only one specific test (let's say test_instance_clustered test only) you can use `focus` or call:
```
APP_ENV=test bundle exec rake test TESTOPTS="--name=test_instance_clustered"
```
Tests are split into several sets and you can replay only one or more set(s):
```
APP_ENV=test bundle exec rake test:api
APP_ENV=test bundle exec rake test:api test:models
```
You can list all available tasks with:
```
bundle exec rake -T
```


You can add your own tests on specific Vehicle Routing Problem (for instance data from real cases). Let's see how to create a new test called "new_test".
You will find template for test in `test/real_cases_test.rb`

Before creating test, you need to capture scenario, in order to have a static image of your problem, insensitive to the routers edits.

Add your test JSON file into the related [gist](https://gist.github.com/braktar/96dcb33063ccddd25e3bb2fd87c38f42). Now to create your test, just copy test template in `test/wrappers/real_cases_test.rb`, or any equivalent file.
Once launched, the dump file of the problem will be created and put as well in the gist as following:
- `new_test.dump` file corresponding to complete vrp with calculated matrices if not provided


If you create a test by using `.dump`, your test will fail as soon as vrp model is changed. Just run following task to update fixtures:
```
TEST_DUMP_VRP=true APP_ENV=test bundle exec rake test TEST=test/real_cases_test.rb
```

Note: you can update a test and run the modified scenario with new vrp `.json`:
```
bundle exec rackup [-p 1791]
COUNT=5 QUEUE=* bundle exec rake resque:workers
curl -X POST --header "Content-Type:application/json" --data @<test/path/>my_test.json http://localhost:1791/0.1/vrp/submit.json?api_key=key
```

If you don't want to run some long real cases tests you can deactivate them:
```
SKIP_REAL_CASES=true APP_ENV=test bundle exec rake test
```
