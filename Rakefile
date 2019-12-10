require 'rubygems'
require 'bundler/setup'
require 'rakeup'
require 'resque/tasks'
require './environment.rb'

RakeUp::ServerTask.new do |t|
  t.port = 1791
  t.pid_file = 'tmp/server.pid'
  t.server = :puma
end

require 'rake/testtask'
Rake::TestTask.new do |t|
  ENV['APP_ENV'] ||= 'test'
  t.pattern = "test/**/*_test.rb"
end

task clean_tmp_dir: :environment do
  require './environment'
  OptimizerWrapper.tmp_vrp_dir.cleanup
end

task clean_dump_dir: :environment do
  require './environment'
  OptimizerWrapper.dump_vrp_dir.cleanup
end

task :environment do
  require './environment'
end
