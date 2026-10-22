# frozen_string_literal: true

require_relative "lib/bulk_destroyer/version"

Gem::Specification.new do |spec|
  spec.name        = "bulk_destroyer"
  spec.version     = BulkDestroyer::VERSION
  spec.authors     = ["Ramanan Neelakantan"]
  spec.email       = ["ramanan.i.neelakantan@gmail.com"]
  spec.summary     = "destroy_all in bulk: every destroy callback fires, rows are deleted with set-based SQL."
  spec.description = <<~DESC
    BulkDestroyer destroys a relation (and its dependent: :destroy tree) while firing every
    destroy callback on every record, but issues one SELECT per association per level and one
    DELETE per table per level instead of one DELETE per row. Works on any ActiveRecord adapter.
  DESC
  spec.homepage    = "https://github.com/rneelakantan/bulk_destroyer"
  spec.license     = "MIT"
  spec.metadata    = {
    "source_code_uri"       => spec.homepage,
    "changelog_uri"         => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri"       => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1", "< 8.3"
end
