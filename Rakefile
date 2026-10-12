# frozen_string_literal: true

require 'rake/testtask'
require 'rubocop/rake_task'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.pattern = 'test/**/*_test.rb'
end

RuboCop::RakeTask.new

desc 'Type-check with Sorbet'
task :sorbet do
  sh 'bundle exec srb tc'
end

task default: %i[test rubocop]
