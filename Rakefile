require 'bundler'
require 'rubygems'
require 'rspec/core/rake_task'
require 'rdoc/task'

Bundler::GemHelper.install_tasks

task :default => :spec

desc "Run specs"
RSpec::Core::RakeTask.new(:spec) do |spec|
  spec.pattern = 'spec/**/*_spec.rb'
end

gem_spec = eval(File.read("knife-hec.gemspec"))
