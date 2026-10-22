# frozen_string_literal: true

# Opt-in benchmark: `rake bench` (or BENCH=1 ruby -Itest test/benchmark_test.rb).
# Skipped by `rake test` because it seeds tens of thousands of rows.
#
#   BENCH_POSTS=1000       posts to seed (each post carries ~17 rows of descendants)
#   BENCH_COMMENTS=5       comments per post
#   BULK_DESTROYER_DB=...  same adapter switch as the rest of the suite
#
# Every strategy runs against identical freshly seeded data, and the test first insists that they
# produce the same end state and fire the same hooks, so the timings compare like with like.
require_relative "test_helper"
require "benchmark"

class BenchLabelsPost < ActiveRecord::Base
  self.table_name = "labels_posts"
end

class DestroyBenchmarkTest < BulkDestroyerTest
  POSTS = Integer(ENV.fetch("BENCH_POSTS", 1_000))
  COMMENTS_PER_POST = Integer(ENV.fetch("BENCH_COMMENTS", 5))

  STRATEGIES = {
    "destroy_all" => -> { Post.destroy_all },
    "find_each(&:destroy)" => -> { Post.find_each(&:destroy) },
    "bulk_destroy_all" => -> { Post.bulk_destroy_all }
  }.freeze

  def setup
    skip "benchmark is opt-in: run `rake bench`" unless ENV["BENCH"]
    super
  end

  def test_destroy_all_vs_destroy_vs_bulk_destroy_all
    STRATEGIES.each_value { |run| warm_up(run) }

    results = STRATEGIES.to_h do |name, run|
      reset
      rows = seed
      [name, measure(name, rows, run)]
    end
    report(results)

    baseline = results.fetch("destroy_all")
    bulk = results.fetch("bulk_destroy_all")

    results.each_value do |r|
      assert_equal baseline[:state], r[:state], "#{r[:name]} must leave the same data behind"
      assert_equal baseline[:hooks], r[:hooks], "#{r[:name]} must fire the same hooks"
    end
    assert_operator bulk[:queries] * 10, :<, baseline[:queries], "bulk_destroy_all should issue at least 10x fewer queries"
    assert_operator bulk[:seconds], :<, baseline[:seconds], "bulk_destroy_all should be faster than destroy_all"
  end

  # 700 posts x 50 comments = 35,700 records with destroy hooks. In one batch that needs 35,700 paused
  # Fibers, past the ~31,700 where Ruby on Linux raises FiberError (vm.max_map_count 65530).
  def test_a_tree_bigger_than_the_fiber_ceiling_is_split_automatically
    reset
    author = Author.create!(name: "big")
    insert(Post, Array.new(700) { |i| { title: "p#{i}", author_id: author.id, comments_count: 50 } })
    post_ids = Post.order(:id).pluck(:id)
    insert(Comment, post_ids.flat_map { |pid| Array.new(50) { { post_id: pid, author_id: author.id, body: "x" } } })
    Author.where(id: author.id).update_all(posts_count: 700, comments_count: 35_000)
    PausedFiberSpy.max = 0

    result = nil
    seconds = Benchmark.realtime { result = Post.bulk_destroy_all }

    puts format("\n  35,700 records, default settings: %.1fs, at most %s Fibers paused at once (max_batch_records=%s)",
                seconds, commas(PausedFiberSpy.max), commas(BulkDestroyer.max_batch_records))
    assert_equal({ "Post" => 700, "Comment" => 35_000 }, result)
    assert_equal 0, Post.count + Comment.count
    assert_equal [0, 0], Author.pick(:posts_count, :comments_count)
    assert_operator PausedFiberSpy.max, :<=, BulkDestroyer.max_batch_records
  end

  private

  def reset
    TABLES.each { |t| ActiveRecord::Base.connection.execute("DELETE FROM #{t}") }
    LOG.clear
  end

  def warm_up(run)
    reset
    seed(posts: 5)
    run.call
    reset
  end

  # Bulk-inserts (no callbacks) a tree with every kind of dependent: association. Counter-cache
  # columns are set to the values real inserts would have produced. => number of rows inserted
  def seed(posts: POSTS)
    author = Author.create!(name: "bench")
    insert(Post, Array.new(posts) { |i| { title: "post #{i}", author_id: author.id, comments_count: COMMENTS_PER_POST } })
    post_ids = Post.order(:id).pluck(:id)
    Author.where(id: author.id).update_all(posts_count: posts, comments_count: posts * COMMENTS_PER_POST)

    insert(Comment, post_ids.flat_map { |pid| Array.new(COMMENTS_PER_POST) { { post_id: pid, author_id: author.id, body: "x" } } })
    comment_ids = Comment.order(:id).pluck(:id)
    insert(Like, comment_ids.map { |cid| { likeable_type: "Comment", likeable_id: cid } })
    insert(Like, post_ids.map { |pid| { likeable_type: "Post", likeable_id: pid } })

    tag = Tag.create!(name: "t")
    label = Label.create!(name: "l")
    insert(Tagging, post_ids.map { |pid| { post_id: pid, tag_id: tag.id } })
    insert(BenchLabelsPost, post_ids.map { |pid| { post_id: pid, label_id: label.id } })
    insert(Audit, post_ids.map { |pid| { post_id: pid } })
    insert(Note, post_ids.map { |pid| { post_id: pid } })
    insert(Detail, post_ids.map { |pid| { post_id: pid } })

    TABLES.sum { |t| row_count(t) }
  end

  def insert(model, rows)
    rows.each_slice(1_000) { |slice| model.insert_all(slice) }
  end

  def row_count(table)
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i
  end

  def measure(name, rows, run)
    LOG.clear
    queries = 0
    counter = lambda do |*, payload|
      sql = payload[:sql]
      queries += 1 unless payload[:name] == "SCHEMA" || sql =~ /\A\s*(SAVEPOINT|RELEASE|BEGIN|COMMIT|ROLLBACK)/i
    end
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    seconds = Benchmark.realtime { ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { run.call } }
    allocated = GC.stat(:total_allocated_objects) - allocated

    state = TABLES.to_h { |t| [t, row_count(t)] }
    state["notes.post_id values"] = Note.distinct.pluck(:post_id)
    state["author counters"] = Author.pick(:posts_count, :comments_count)
    { name: name, rows: rows, seconds: seconds, queries: queries, allocated: allocated,
      hooks: LOG.map { |e| e[0, 2] }.tally, hook_count: LOG.size, state: state }
  end

  def report(results)
    base = results.fetch("destroy_all")
    adapter = ActiveRecord::Base.connection.adapter_name
    puts
    puts "  #{POSTS} posts x #{COMMENTS_PER_POST} comments -> #{commas(base[:rows])} rows seeded per run " \
         "(#{adapter}, Rails #{ActiveRecord.version}, Ruby #{RUBY_VERSION})"
    puts format("  %-22s %9s %11s %12s %10s %9s", "strategy", "seconds", "queries", "allocations", "hook calls", "speedup")
    results.each_value do |r|
      puts format("  %-22s %9.2f %11s %12s %10s %8.1fx", r[:name], r[:seconds], commas(r[:queries]),
                  commas(r[:allocated]), commas(r[:hook_count]), base[:seconds] / r[:seconds])
    end
    puts
  end

  def commas(n)
    n.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  end
end
