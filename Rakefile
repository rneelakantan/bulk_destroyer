# frozen_string_literal: true

require "rake/testtask"
Rake::TestTask.new(:test) { |t| t.libs << "test"; t.pattern = "test/**/*_test.rb" }
desc "Benchmark destroy_all vs find_each(&:destroy) vs bulk_destroy_all (BENCH_POSTS=1000 BENCH_COMMENTS=5)"
task :bench do
  ENV["BENCH"] = "1"
  ruby "-Itest", "test/benchmark_test.rb"
end

task default: :test
