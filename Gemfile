source 'https://rubygems.org'
ruby '>= 3.3'

gem 'require_all'

gem 'puma', '~> 8.0'
gem 'rack'
gem 'rack-contrib', require: 'rack/contrib'
gem 'rack-cors', require: 'rack/cors'
gem 'rack-server-pages'
gem 'rake'

# API
# ~> 3.2: ParamScopeTracker (thread-safe validation); keeps mustermann 3.x (sinatra/resque)
# grape >= 3.3 / mustermann 4 need Ruby >= 3.3 — still blocked by sinatra ~> mustermann 3 until Sinatra 5
gem 'grape', '~> 3.2.0'
gem 'grape-entity'
gem 'grape_logging', '>= 3.0'
gem 'grape-swagger', '~> 2.1', '>= 2.1.3' # 2.1.3+ allows grape < 4; 2.2 needs Ruby >= 3.1 OK
gem 'grape-swagger-entity'

# Models
gem 'actionpack', '>= 8.0', require: 'action_dispatch'
# waiting for the following PRs to get merged and "released!"
# https://github.com/zilkey/active_hash/pull/231 and https://github.com/zilkey/active_hash/pull/233
gem 'active_hash'
gem 'activemodel', '>= 8.0'
gem 'activesupport', '>= 8.0', require: 'active_support'
gem 'google-protobuf', '>=3', require: 'google/protobuf'
gem 'oj'
# json 3 removed quirks_mode; Grape formatter still passes it
gem 'json', '~> 2.0'

# Text
gem 'charlock_holmes'
gem 'http_accept_language'
gem 'i18n'

# Queue
gem 'redis', '<4'
gem 'resque', '<2'
# Hard fork: upstream quirkey/resque-status dead since 2015 (pinned resque ~> 1.19)
gem 'resque-status', github: 'cartoway/resque-status'
# Keep mustermann 3.x: mustermann 4 pulls Sinatra 1.0 via resolver (Sinatra 2–4 pin ~> 3.0)
gem 'mustermann', '~> 3.1'

# Web
gem 'rest-client'

# AI
# Still needed for hierarchical CompleteLinkage / AverageLinkage clusterers.
gem 'ai4r'
gem 'balanced_vrp_clustering', '~> 0.4' # 0.4+ vendors Ai4r::DataSet/Clusterer (no ai4r runtime dep)

# Geo
gem 'polylines'
gem 'rgeo'
gem 'rgeo-geojson', require: 'rgeo/geo_json'

gem 'sentry-resque'
gem 'sentry-ruby'

group :development do
  # Offline code analysis / IDE (not needed in CI test image)
  gem 'ripper-tags'
  gem 'solargraph'
end

group :development, :test do
  gem 'benchmark-ips' # to in-place benchmark of different implementations
  gem 'byebug'

  # For creating dependency graphs
  # gem 'rubrowser' # active to create graph

  # For debugging memory issues
  # gem 'heap-profiler'   # active to create graph
  # gem 'memory_profiler' # active to create graph

  ## Next gems to use the debuger of vscode directly
  ## but due to a bug in rubyide/vscode-ruby it doesn't
  ## work at the moment with rake::workers
  # gem 'psych', '<3.0.2' # TODO: Waiting Ruby 2.2
  # gem 'ruby-debug-ide'
  # gem 'debase'
end

group :rubocop do
  # Linting
  gem 'rubocop'
  gem 'rubocop-policy', github: 'cartoway/rubocop-policy', tag: 'v0.3.0'
end

group :test do
  gem 'dotenv'
  gem 'minitest', '~> 5.0', require: 'minitest/autorun' # 6.x breaks reporters ProgressReporter
  # 0.6 + reporters 1.8 recurse in run_with_hooks (SystemStackError)
  gem 'minitest-around', '~> 0.5.0' # block around unit tests for initialisation and cleanup
  gem 'minitest-bisect' # useful for identifing randomly failing order-depoendent tests
  gem 'minitest-focus', require: 'minitest/focus'
  gem 'minitest-reporters', '~> 1.6.0', require: 'minitest/reporters'
  gem 'minitest-retry', require: 'minitest/retry' # relaunches selected methods when they fail
  gem 'minitest-stub_any_instance', require: 'minitest/stub_any_instance'
  gem 'rack-test', require: 'rack/test'
  gem 'simplecov', require: false
  gem 'webmock', require: 'webmock/minitest'
end
