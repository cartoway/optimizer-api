# frozen_string_literal: true

if ENV['SENTRY_DSN']
  Sentry.init { |config|
    config.dsn = ENV['SENTRY_DSN']
  }
elsif ENV['APP_ENV'] == 'production'
  puts 'WARNING: Sentry DSN should be defined for production'
end
