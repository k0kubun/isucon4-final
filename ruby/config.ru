require_relative './app.rb'
if ENV['RACK_ENV'] == 'production'
  require 'newrelic_rpm'
end

run Isucon4::App
