# frozen_string_literal: true

require_relative "test_helper"

class BulkDestroyAllTest < BulkDestroyerTest
  def test_destroys_the_whole_tree_and_fires_every_hook_once
    post = build_post
    result = Post.where(id: post.id).bulk_destroy_all

    assert_equal 0, Post.count + Comment.count + Like.count + Tagging.count + Audit.count + Detail.count
    assert_equal 1, result["Post"]
    assert_equal 2, result["Comment"]
    assert_equal 3, result["Like"]

    { "Post" => 1, "Comment" => 2, "Like" => 3, "Tagging" => 1, "Detail" => 1 }.each do |klass, n|
      %i[before around_pre around_post after commit].each do |kind|
        assert_equal n, events(kind, klass).size, "#{kind} for #{klass}"
      end
    end
  end

  def test_things_that_must_survive_survive
    post = build_post
    Post.where(id: post.id).bulk_destroy_all

    assert_equal 1, Tag.count, "has_many :through must delete join rows only, never the far side"
    assert_equal 1, Label.count, "HABTM must delete join rows only"
    assert_equal 0, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM labels_posts")
    assert_equal [nil], Note.pluck(:post_id), "dependent: :nullify"
    assert_equal 0, Audit.count, "dependent: :delete_all"
  end

  def test_hook_ordering_matches_plain_destroy
    post = build_post(comments: 1)
    Post.where(id: post.id).bulk_destroy_all
    names = LOG.map { |e| e[0, 2] }

    assert_operator names.index([:before, "Post"]), :<, names.index([:before, "Comment"]), "parent before_destroy first"
    assert_operator names.index([:around_pre, "Comment"]), :<, names.index([:around_post, "Comment"])
    assert_operator names.index([:after, "Comment"]), :<, names.index([:after, "Post"]), "child after_destroy before parent's"
  end

  def test_after_destroy_runs_after_the_row_is_deleted_and_parent_still_exists_for_children
    Loggable.probe = true
    post = build_post(comments: 1)
    Post.where(id: post.id).bulk_destroy_all

    assert_equal [false], events(:after, "Post").map(&:last), "after_destroy sees the row gone"
    assert_equal [false], events(:after, "Comment").map(&:last)
  end

  def test_child_after_destroy_runs_while_parent_row_still_exists
    Loggable.probe = true
    post = build_post(comments: 1)
    Post.where(id: post.id).bulk_destroy_all
    assert_equal [[:parent_present, true]], events(:parent_present),
                 "same ordering as destroy: a child finishes before its parent's row is deleted"
  end

  def test_conditional_callbacks_are_respected
    post = Post.create!(title: "p")
    Comment.create!(post: post, body: "run")
    Comment.create!(post: post, body: "skip")
    Post.where(id: post.id).bulk_destroy_all

    assert_equal 1, events(:conditional_ran).size
  end

  def test_query_count_does_not_grow_with_the_number_of_records
    small_author = Author.create!(name: "a")
    3.times { build_post(author: small_author, comments: 2) }
    small = count_queries { Post.bulk_destroy_all }

    big_author = Author.create!(name: "b")
    20.times { build_post(author: big_author, comments: 5) }
    big = count_queries { Post.bulk_destroy_all }

    assert_equal small, big
    assert_operator big, :<, 40
  end

  def test_counter_caches
    author = Author.create!(name: "a")
    keep = Post.create!(title: "keep", author: author)
    gone = Post.create!(title: "gone", author: author)
    2.times { Comment.create!(post: gone, author: author, body: "x") }
    Comment.create!(post: keep, author: author, body: "x")
    assert_equal 3, author.reload.comments_count
    assert_equal 2, author.posts_count

    Comment.where(post: gone).bulk_destroy_all
    assert_equal 1, author.reload.comments_count
    assert_equal 0, gone.reload.comments_count
    assert_equal 1, keep.reload.comments_count

    Post.where(id: gone.id).bulk_destroy_all
    assert_equal 1, author.reload.posts_count
  end

  def test_abort_rolls_back_everything_and_unwinds_hooks
    post = Post.create!(title: "p")
    Comment.create!(post: post, body: "x")
    Comment.create!(post: post, body: "abort")

    error = assert_raises(ActiveRecord::RecordNotDestroyed) { Post.where(id: post.id).bulk_destroy_all }
    assert_match(/Comment/, error.message)
    assert_equal 1, Post.count
    assert_equal 2, Comment.count
    assert_equal events(:around_pre).size, events(:around_ensure).size, "every started around hook is unwound"
  end

  def test_failure_after_delete_rolls_back_and_restores_record_state
    post = build_post
    Loggable.explode_in = "Detail"
    loaded = Post.find(post.id)

    assert_raises(RuntimeError) { Post.where(id: post.id).bulk_destroy_all }
    assert_equal 1, Post.count
    assert_equal 1, Detail.count
    assert_equal 0, events(:commit).size

    Loggable.explode_in = nil
    assert_equal 1, Post.where(id: loaded.id).bulk_destroy_all["Post"]
  end

  def test_after_commit_fires_only_after_the_outer_transaction_commits
    post = build_post(comments: 1)
    Post.transaction do
      Post.where(id: post.id).bulk_destroy_all
      assert_equal 0, events(:commit).size
    end
    assert_equal 1, events(:commit, "Post").size
    assert_equal 1, events(:commit, "Comment").size
  end

  def test_after_commit_not_fired_when_outer_transaction_rolls_back
    post = build_post(comments: 1)
    Post.transaction do
      Post.where(id: post.id).bulk_destroy_all
      raise ActiveRecord::Rollback
    end
    assert_equal 0, events(:commit).size
    assert_equal 1, Post.count
  end

  def test_self_referential_tree_is_deleted_children_first_under_fk_constraints
    root = Category.create!(name: "r")
    a = Category.create!(name: "a", parent: root)
    b = Category.create!(name: "b", parent: a)
    Category.create!(name: "c", parent: b)
    Category.create!(name: "other", parent: root)

    assert_equal 5, Category.where(id: root.id).bulk_destroy_all["Category"]
    assert_equal 0, Category.count
    assert_equal 5, events(:after, "Category").size
  end

  def test_records_reachable_by_two_paths_are_deleted_after_everything_that_references_them
    # a Like on a Comment on a Post is also reachable one level up if the post owns it directly
    post = Post.create!(title: "p")
    comment = Comment.create!(post: post, body: "x")
    Like.create!(likeable: comment)
    Like.create!(likeable: post)
    assert_equal({ "Post" => 1, "Comment" => 1, "Like" => 2 }, Post.where(id: post.id).bulk_destroy_all)
  end

  def test_batches
    5.times { Post.create!(title: "p") }
    assert_equal({ "Post" => 5 }, Post.bulk_destroy_all(batch_size: 2))
    assert_equal 5, events(:after, "Post").size
  end

  def test_single_record_and_association_proxy_and_marks_destroyed
    post = build_post
    post.bulk_destroy!
    assert post.destroyed?
    assert post.frozen?
    assert_equal 0, Post.count

    other = build_post
    assert_equal 2, other.comments.bulk_destroy_all["Comment"]
  end

  def test_restrict_with_exception_blocks_before_any_hook_runs
    author = Author.create!(name: "a")
    Vault.create!(author: author)
    Post.create!(title: "p", author: author)

    assert_raises(ActiveRecord::DeleteRestrictionError) { Author.where(id: author.id).bulk_destroy_all }
    assert_equal 1, Post.count
    assert_empty events(:before)
  end

  def test_plain_destroy_still_works_normally_after_bulk_destroy
    build_post.bulk_destroy!
    LOG.clear
    post = build_post
    post.destroy
    assert_equal 0, Post.count
    assert_equal 1, events(:after, "Post").size
  end

  def test_inline_mode
    previous = BulkDestroyer.hook_mode
    BulkDestroyer.hook_mode = :inline
    Loggable.probe = true
    post = build_post(comments: 1)
    Post.where(id: post.id).bulk_destroy_all
    assert_equal [true], events(:after, "Post").map(&:last), "inline mode runs after_destroy before the DELETE"
    assert_equal 0, Post.count
  ensure
    BulkDestroyer.hook_mode = previous
  end

  def test_belongs_to_destroy_async_is_rejected_loudly
    stub = Struct.new(:options, :active_record, :name, :macro) { def belongs_to? = true }
                 .new({ dependent: :destroy_async }, Comment, :post, :belongs_to)
    error = assert_raises(BulkDestroyer::UnsupportedAssociation) { BulkDestroyer::Dependents.classify(stub) }
    assert_match(/destroy_async/, error.message)
  end
end

class ParityWithDestroyAllTest < BulkDestroyerTest
  def hook_multiset
    LOG.map { |e| e[0, 2] }.tally
  end

  def test_fires_exactly_the_hooks_stock_destroy_all_fires
    author = Author.create!(name: "a")
    3.times { build_post(author: author, comments: 2) }
    Comment.first.update!(body: "run")
    snapshot = ->(&blk) { LOG.clear; blk.call; [hook_multiset, Author.first.comments_count, Author.first.posts_count, Tag.count, Label.count, Note.pluck(:post_id).uniq] }

    # re-run both inside rolled-back transactions so they start from identical data
    stock_state = bulk_state = nil
    ActiveRecord::Base.transaction { stock_state = snapshot.call { Post.destroy_all }; raise ActiveRecord::Rollback }
    ActiveRecord::Base.transaction { bulk_state = snapshot.call { Post.bulk_destroy_all }; raise ActiveRecord::Rollback }

    assert_equal stock_state, bulk_state
  end

  def test_reports_query_savings
    author = Author.create!(name: "a")
    10.times { build_post(author: author, comments: 5) }
    stock = bulk = nil
    ActiveRecord::Base.transaction { stock = count_queries { Post.destroy_all }; raise ActiveRecord::Rollback }
    ActiveRecord::Base.transaction { bulk = count_queries { Post.bulk_destroy_all }; raise ActiveRecord::Rollback }
    puts "\n  queries for 10 posts / 50 comments / ~130 rows: destroy_all=#{stock} bulk_destroy_all=#{bulk}"
    assert_operator bulk, :<, stock / 10
  end
end


class BatchRecordCapTest < BulkDestroyerTest
  def hook_tally
    LOG.map { |e| e[0, 2] }.tally
  end

  def test_a_batch_over_the_cap_is_split_and_everything_still_happens_once
    10.times { build_post(comments: 2) } # 8 records with destroy hooks per post -> 80 in one batch

    stock = bulk = nil
    ActiveRecord::Base.transaction { LOG.clear; Post.destroy_all; stock = hook_tally; raise ActiveRecord::Rollback }
    ActiveRecord::Base.transaction do
      LOG.clear
      with_config(hook_mode: :fiber, max_batch_records: 25) { Post.bulk_destroy_all }
      bulk = hook_tally
      raise ActiveRecord::Rollback
    end
    assert_equal stock, bulk, "same hooks, each fired exactly once"
    assert_operator PausedFiberSpy.max, :<=, 25, "no batch ever held more paused Fibers than the cap"
    assert_operator PausedFiberSpy.max, :<, 80, "it did split"

    PausedFiberSpy.max = 0
    result = with_config(hook_mode: :fiber, max_batch_records: 25) { Post.bulk_destroy_all }
    assert_equal 10, result["Post"]
    assert_equal 20, result["Comment"]
    assert_equal 0, Post.count + Comment.count + Like.count + Tagging.count + Detail.count
    assert_operator PausedFiberSpy.max, :<=, 25
  end

  def test_default_cap_does_not_change_small_runs
    3.times { build_post }
    with_config(hook_mode: :fiber) { Post.bulk_destroy_all }
    assert_equal 0, Post.count
    assert_equal 3 * 8, PausedFiberSpy.max, "one batch, every record paused at once, as before"
  end

  def test_one_root_over_the_cap_raises_a_clear_error_before_any_hook_runs
    post = build_post(comments: 10)

    error = with_config(hook_mode: :fiber, max_batch_records: 5) do
      assert_raises(BulkDestroyer::TreeTooLarge) { Post.where(id: post.id).bulk_destroy_all }
    end
    assert_match(/max_batch_records/, error.message)
    assert_match(/oversized_tree = :inline/, error.message)
    assert_empty LOG
    assert_equal 1, Post.count
    assert_equal 10, Comment.count
  end

  def test_one_root_over_the_cap_can_fall_back_to_inline_hooks
    post = build_post(comments: 10)

    with_config(hook_mode: :fiber, max_batch_records: 5, oversized_tree: :inline) do
      assert_equal 1, Post.where(id: post.id).bulk_destroy_all["Post"]
    end
    assert_equal 0, Post.count + Comment.count
    assert_equal 0, PausedFiberSpy.max, "no Fibers were used"
    assert_equal 10, events(:after, "Comment").size
    assert_equal 1, events(:after, "Post").size
  end

  def test_belongs_to_targets_are_split_too
    6.times { Entry.create!(entryable: Message.create!(body: "m").tap { |m| 2.times { Clip.create!(message: m) } }) }

    # 6 entries fit in one batch (6 <= 9); the 6 messages with their clips are 18 records, so they run as 3 + 3
    result = with_config(hook_mode: :fiber, max_batch_records: 9) { Entry.bulk_destroy_all }

    assert_equal({ "Entry" => 6, "Message" => 6, "Clip" => 12 }, result)
    assert_equal 0, Entry.count + Message.count + Clip.count
    assert_equal 6, events(:after, "Message").size
    assert_equal 12, events(:after, "Clip").size
    assert_operator PausedFiberSpy.max, :<=, 9
  end

  def test_inline_hook_mode_ignores_the_cap
    post = build_post(comments: 10)
    with_config(hook_mode: :inline, max_batch_records: 5) { Post.where(id: post.id).bulk_destroy_all }
    assert_equal 0, Post.count
  end
end

class RollbackInHookTest < BulkDestroyerTest
  def test_a_hook_raising_rollback_is_reported_instead_of_silently_skipping_the_batch
    post = build_post
    Loggable.rollback_in = "Comment"

    error = assert_raises(ActiveRecord::RecordNotDestroyed) { Post.where(id: post.id).bulk_destroy_all }
    assert_match(/ActiveRecord::Rollback was raised/, error.message)
    assert_match(/1 Post record/, error.message)
    assert_equal 1, Post.count
    assert_equal 2, Comment.count
    assert_equal 0, events(:commit).size
  end

  def test_the_same_inside_a_callers_transaction_leaves_it_usable
    post = build_post
    Loggable.rollback_in = "Comment"

    Post.transaction do
      Post.create!(title: "written before")
      assert_raises(ActiveRecord::RecordNotDestroyed) { Post.where(id: post.id).bulk_destroy_all }
      assert_equal 2, Post.count, "the batch was rolled back to its savepoint, the caller's own write is intact"
    end
    assert_equal 2, Post.count
  end

  def test_earlier_batches_stay_committed_when_a_later_batch_rolls_back
    first = Post.create!(title: "first")
    second = Post.create!(title: "second")
    Loggable.rollback_in = "Post"
    Loggable.rollback_title = "second"

    assert_raises(ActiveRecord::RecordNotDestroyed) { Post.bulk_destroy_all(batch_size: 1) }
    assert_equal [second.id], Post.pluck(:id), "the first batch was its own transaction and stays destroyed"
    assert_equal 1, events(:commit, "Post").size
    refute_includes Post.pluck(:id), first.id
  end
end

class AssociationKindsTest < BulkDestroyerTest
  def test_has_many_through_dependent_destroy_removes_join_records_only_like_rails
    course = Course.create!(name: "c")
    2.times { |i| Enrollment.create!(course: course, student: Student.create!(name: "s#{i}")) }
    other = Course.create!(name: "other")
    Enrollment.create!(course: other, student: Student.first)

    run = lambda do |&blk|
      LOG.clear
      blk.call
      [LOG.map { |e| e[0, 2] }.tally, Enrollment.count, Student.count, Course.count]
    end
    stock = bulk = nil
    ActiveRecord::Base.transaction { stock = run.call { Course.where(id: course.id).destroy_all }; raise ActiveRecord::Rollback }
    ActiveRecord::Base.transaction { bulk = run.call { Course.where(id: course.id).bulk_destroy_all }; raise ActiveRecord::Rollback }
    assert_equal stock, bulk

    LOG.clear
    result = Course.where(id: course.id).bulk_destroy_all
    assert_equal({ "Course" => 1, "Enrollment" => 2 }, result)
    assert_equal 2, Student.count, "the far side of a through association is never destroyed"
    assert_equal 1, Enrollment.count, "another course's enrollments are untouched"
    assert_equal 2, events(:after, "Enrollment").size
  end

  def test_polymorphic_delete_all_and_nullify_only_touch_rows_of_the_right_type
    gadget = Gadget.create!(id: 7, name: "g")
    gizmo = Gizmo.create!(id: 7, name: "z")
    2.times { Reaction.create!(target: gadget) }
    Reaction.create!(target: gizmo)
    2.times { Mark.create!(target: gadget) }
    Mark.create!(target: gizmo)

    assert_equal({ "Gadget" => 1, "Reaction" => 2 }, Gadget.where(id: 7).bulk_destroy_all)

    assert_equal [["Gizmo", 7]], Reaction.pluck(:target_type, :target_id), "same id, different type: must survive"
    assert_equal 3, Mark.count
    assert_equal [[nil, nil], [nil, nil]], Mark.where(target_id: nil).pluck(:target_type, :target_id), "nullify clears the type column too"
    assert_equal [["Gizmo", 7]], Mark.where.not(target_id: nil).pluck(:target_type, :target_id)
  end

  def test_habtm_from_the_other_side_deletes_join_rows_and_keeps_the_posts
    post = Post.create!(title: "p")
    label = Label.create!(name: "l")
    post.labels << label
    Post.create!(title: "p2").labels << Label.create!(name: "l2")

    assert_equal({ "Label" => 1 }, Label.where(id: label.id).bulk_destroy_all)
    assert_equal 2, Post.count
    assert_equal 1, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM labels_posts").to_i
  end
end

class BelongsToDependentTest < BulkDestroyerTest
  def entry_with_message(body: "hi", clips: 2)
    message = Message.create!(body: body)
    clips.times { Clip.create!(message: message) }
    Entry.create!(entryable: message)
  end

  def test_delegated_type_target_is_destroyed_with_its_own_hooks_and_children
    entry = entry_with_message
    result = Entry.where(id: entry.id).bulk_destroy_all

    assert_equal({ "Entry" => 1, "Message" => 1, "Clip" => 2 }, result)
    assert_equal 0, Entry.count + Message.count + Clip.count
    { "Entry" => 1, "Message" => 1, "Clip" => 2 }.each do |klass, n|
      %i[before around_pre around_post after commit].each do |kind|
        assert_equal n, events(kind, klass).size, "#{kind} for #{klass}"
      end
    end
  end

  def test_target_is_destroyed_after_the_owner_row_is_gone
    Loggable.probe = true
    entry = entry_with_message(clips: 0)
    Entry.where(id: entry.id).bulk_destroy_all
    names = LOG.map { |e| e[0, 2] }

    assert_operator names.index([:after, "Entry"]), :<, names.index([:before, "Message"]), "same order as Rails: target is destroyed from the owner's after_destroy"
    assert_equal [false], events(:after, "Entry").map(&:last), "owner row already deleted"
  end

  def test_same_hooks_and_rows_as_stock_destroy_all
    3.times { entry_with_message }
    run = lambda do |&blk|
      LOG.clear
      blk.call
      [LOG.map { |e| e[0, 2] }.tally, Entry.count, Message.count, Clip.count]
    end
    stock = bulk = nil
    ActiveRecord::Base.transaction { stock = run.call { Entry.destroy_all }; raise ActiveRecord::Rollback }
    ActiveRecord::Base.transaction { bulk = run.call { Entry.bulk_destroy_all }; raise ActiveRecord::Rollback }

    assert_equal stock, bulk
  end

  def test_a_target_shared_by_two_owners_is_destroyed_once
    message = Message.create!(body: "shared")
    2.times { Entry.create!(entryable: message) }

    assert_equal({ "Entry" => 2, "Message" => 1 }, Entry.bulk_destroy_all)
    assert_equal 1, events(:after, "Message").size
  end

  def test_owners_without_a_target_are_fine
    Entry.create!(entryable_type: nil, entryable_id: nil)
    entry_with_message(clips: 0)
    assert_equal({ "Entry" => 2, "Message" => 1 }, Entry.bulk_destroy_all)
  end

  def test_query_count_does_not_grow_with_the_number_of_owners
    3.times { entry_with_message }
    small = count_queries { Entry.bulk_destroy_all }
    20.times { entry_with_message }
    big = count_queries { Entry.bulk_destroy_all }

    assert_equal small, big
  end

  def test_two_models_that_destroy_each_other_terminate_from_either_side
    memo = Memo.create!(body: "m")
    Slot.create!(holder: memo)
    assert_equal({ "Slot" => 1, "Memo" => 1 }, Slot.bulk_destroy_all)
    assert_equal 1, events(:after, "Memo").size
    assert_equal 1, events(:after, "Slot").size

    LOG.clear
    memo = Memo.create!(body: "m")
    Slot.create!(holder: memo)
    assert_equal({ "Memo" => 1, "Slot" => 1 }, Memo.bulk_destroy_all)
    assert_equal 1, events(:after, "Memo").size
    assert_equal 1, events(:after, "Slot").size
    assert_equal 0, Memo.count + Slot.count
  end

  def test_dependent_delete_removes_the_target_without_callbacks
    snippet = Snippet.create!(body: "s")
    ticket = Ticket.create!(snippet: snippet)

    assert_equal({ "Ticket" => 1, "Snippet" => 1 }, Ticket.where(id: ticket.id).bulk_destroy_all)
    assert_equal 0, Ticket.count + Snippet.count
  end

  def test_an_aborting_target_hook_rolls_back_the_owner_too
    entry = entry_with_message(body: "abort")

    assert_raises(ActiveRecord::RecordNotDestroyed) { Entry.where(id: entry.id).bulk_destroy_all }
    assert_equal 1, Entry.count
    assert_equal 1, Message.count
    assert_equal 2, Clip.count
    assert_equal events(:around_pre).size, events(:around_ensure).size
  end

  def test_works_inside_an_outer_transaction_and_commit_hooks_wait_for_it
    entry = entry_with_message(clips: 1)
    Entry.transaction do
      Entry.where(id: entry.id).bulk_destroy_all
      assert_equal 0, events(:commit).size
    end
    assert_equal 1, events(:commit, "Entry").size
    assert_equal 1, events(:commit, "Message").size
    assert_equal 1, events(:commit, "Clip").size
  end
end

class ThroughCollectionGuardTest < BulkDestroyerTest
  def setup_course
    course = Course.create!
    other = Course.create!
    students = 2.times.map { |i| Student.create!(name: "s#{i}") }
    students.each { |st| Enrollment.create!(course: course, student: st) }
    Enrollment.create!(course: other, student: students.first)
    course
  end

  def test_bulk_destroy_all_on_a_through_collection_is_refused_and_deletes_nothing
    course = setup_course
    error = assert_raises(BulkDestroyer::UnsupportedAssociation) { course.students.bulk_destroy_all }
    assert_match(/Course#students/, error.message)
    assert_match(/Course#enrollments/, error.message)
    assert_equal [2, 3], [Student.count, Enrollment.count]
  end

  def test_through_collection_is_refused_with_a_custom_batch_size
    course = setup_course
    assert_raises(BulkDestroyer::UnsupportedAssociation) { course.students.bulk_destroy_all(batch_size: 10) }
    assert_equal 2, Student.count
  end

  def test_direct_collection_and_join_model_still_work
    course = setup_course
    course.enrollments.bulk_destroy_all
    assert_equal [2, 1], [Student.count, Enrollment.count], "join rows go, students and other course stay"
  end

  def test_far_side_model_relation_still_works
    setup_course
    Enrollment.delete_all
    Student.where(name: "s0").bulk_destroy_all
    assert_equal 1, Student.count
  end

  def test_habtm_collection_is_refused_too
    post = build_post
    assert_raises(BulkDestroyer::UnsupportedAssociation) { post.labels.bulk_destroy_all }
    assert_equal 1, Label.count
  end
end
