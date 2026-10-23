# BulkDestroyer

`destroy_all` that fires **every destroy callback on every record** (including `dependent: :destroy`
descendants) but deletes with set-based SQL.

```ruby
Post.where(archived: true).bulk_destroy_all            # => { "Post" => 120, "Comment" => 940, ... }
Post.bulk_destroy_all(batch_size: 500)
post.comments.bulk_destroy_all
post.bulk_destroy!
```

See [Benchmarks](#benchmarks) for timings. Query count is roughly one SELECT per association per level plus one DELETE
per 500 ids (`in_list_size`) per table, repeated for each batch of `batch_size` roots. It still grows with the
data, but about 700x more slowly than `destroy_all`'s two-plus queries per row (32,001 vs 45 queries at 1,000
posts, 160,001 vs 221 at 5,000).

## How it works

Per batch of roots (default 1000, and never more than `max_batch_records` records; see below), inside one
transaction (`requires_new: true`):

1. **Tree** - `ActiveRecord::Associations::Preloader` loads each `dependent: :destroy` association
   once per level. Association scopes, `foreign_key`/`primary_key`, polymorphic `as:` and STI are
   handled by Rails. A record reachable by several paths is placed at its deepest level.
2. **Restrictions** - `restrict_with_exception` / `restrict_with_error` are checked first.
3. **Start hooks** - each record's real `run_callbacks(:destroy)` runs inside a `Fiber` up to the
   point where Rails would delete the row (before_destroy, first half of around_destroy), parents first.
4. **Per level, deepest first** - `nullify` / `delete_all` / HABTM join rows, then one bulk `DELETE`
   per table, then counter caches, then the records are marked destroyed and their fibers resume
   (second half of around_destroy, `after_destroy`).

Because Rails runs the callback chain itself, `if:`/`unless:`, `prepend:`, callback objects, ordering
and `throw :abort` behave as in `destroy`. `after_destroy` really runs after the row is gone, and a
child's `after_destroy` runs while its parent's row still exists (same as `destroy`).

`after_commit` / `after_rollback` work: records are registered with the transaction exactly as
`destroy` registers them, so Active Storage purges etc. fire at commit, and a rolled-back batch
restores `destroyed?`.

## Association support

| Association | How it is handled | Covered by a test |
|---|---|---|
| `has_many` / `has_one`, `dependent: :destroy` | children loaded once per level, destroyed with their hooks | yes |
| polymorphic `has_many ... as:`, `dependent: :destroy` | same, type column respected | yes (likes on posts and comments) |
| polymorphic `as:`, `dependent: :delete_all` / `:nullify` | one `DELETE` / `UPDATE` filtered by owner id **and** type; nullify clears the type column too | yes (two classes sharing an id) |
| `has_many :through` (plain `has_many` for the join, `dependent: :destroy` there) | join rows destroyed, far side untouched | yes |
| `has_many :through ..., dependent: :destroy` on the through association itself | join records destroyed with their hooks, far side untouched (same as Rails) | yes, compared with stock `destroy_all` |
| `has_and_belongs_to_many` | join rows deleted without callbacks (Rails does the same), from either side; far side untouched | yes |
| `belongs_to ..., dependent: :destroy` / `:delete`, polymorphic and `delegated_type` | target destroyed after its owners, see below | yes |
| `dependent: :restrict_with_exception` / `:restrict_with_error` | checked before any hook runs | exception form only |
| `dependent: :destroy_async`, nested `:through` with `dependent:` | raises `BulkDestroyer::UnsupportedAssociation` | `destroy_async` only |

The hash returned by `bulk_destroy_all` counts rows deleted per table, including `dependent: :delete_all` rows and
`dependent: :delete` targets. HABTM join rows and `nullify`d rows are not counted.

## Differences from `destroy_all` (by design)

- All `before_destroy` hooks run before any row is deleted, rather than interleaved with child deletion.
- `throw :abort` / a failing hook rolls back the **whole batch** and raises
  `ActiveRecord::RecordNotDestroyed` (or the hook's own error). There is no per-record skipping.
  Batches are separate transactions; wrap the call in your own `transaction` for all-or-nothing.
  A hook that raises `ActiveRecord::Rollback` is treated the same way: Rails' `transaction` would swallow it
  and the batch would silently disappear, so the gem raises `ActiveRecord::RecordNotDestroyed` instead.
- `has_many :through, dependent: :destroy` and `has_and_belongs_to_many` remove join rows only (as Rails does).
- `belongs_to ..., dependent: :destroy` / `:delete` (this is what `delegated_type ..., dependent: :destroy` declares)
  is supported. Rails destroys that target from the owner's `after_destroy`, so here each level of owners is
  deleted first and then their targets are destroyed in a nested pass inside the same transaction, with their
  own hooks, children and further `belongs_to` targets. Targets are preloaded (one query per target class,
  polymorphic included), a target shared by several owners is destroyed once, and models that destroy each
  other (`Slot belongs_to :holder, dependent: :destroy` / `Memo has_one :slot, dependent: :destroy`) terminate.
  A target whose `before_destroy` aborts rolls back the whole batch, owners included.
- Counter caches are decremented with one grouped UPDATE per (column, amount) instead of one per row.
- `touch: true` is a callback and still runs per record.
- `destroy` itself is never called, so a model that overrides `destroy` (soft-delete gems) is bypassed.
  Optimistic locking (`lock_version`) is not checked.

## Not supported (raises `BulkDestroyer::UnsupportedAssociation`)

`dependent: :destroy_async` (on any association), nested `:through`, `:nullify` on `:through`,
and, for `delete_all`/`nullify`/`restrict`, composite foreign keys and instance-dependent scopes
(`-> (owner) { ... }`). (`dependent: :destroy` goes through Rails' preloader and does not have the
last two limits.)

**Calling `bulk_destroy_all` directly on a `has_many :through` or HABTM collection** (`course.students.bulk_destroy_all`)
is refused too. Rails' own `course.students.destroy_all` removes only the join rows and keeps the students, whereas a
relation-level destroy would delete the `Student` records themselves, for every course they are enrolled in. The error
tells you which call you meant:

```ruby
course.enrollments.bulk_destroy_all          # remove the join rows only (what Rails' destroy_all does)
Student.where(...).bulk_destroy_all          # really destroy the Students
```

(`course.students.where(...).bulk_destroy_all` is a plain relation of `Student` and, like Rails' own
`course.students.where(...).destroy_all`, destroys those students.)

## Configuration

```ruby
BulkDestroyer.batch_size   = 1_000    # roots per transaction
BulkDestroyer.in_list_size = 500      # values per IN (...) chunk, capped per adapter
BulkDestroyer.hook_mode    = :fiber   # or :inline
BulkDestroyer.max_batch_records = 10_000   # records with destroy hooks per batch (see below)
BulkDestroyer.oversized_tree    = :raise   # or :inline, when ONE root's tree exceeds the cap
```

`:fiber` needs `ActiveSupport::IsolatedExecutionState.isolation_level == :thread` (the default) because
hook fibers must share the caller's database connection; otherwise it raises `UnsupportedIsolation`.
`:inline` runs the whole callback chain before the DELETE (so `after_destroy` still sees the row).
Fiber-local `Thread.current[:x]` values are copied into the hook fibers.

### The Fiber ceiling and `max_batch_records`

In `:fiber` mode every record in a batch's tree keeps one paused Fiber until its level has been deleted, so a
batch holds as many live Fibers as it has records with destroy hooks (the `batch_size` of 1000 counts roots, not
records). Ruby on Linux fails with `FiberError: can't set a guard page` at about 31,700 live Fibers with the
default `vm.max_map_count` of 65530 (two memory mappings per Fiber stack); measured on Ruby 3.4, trivial Fibers
cost about 12 KB each, real hook stacks cost more. A tree of 700 posts with 50 comments each (35,700 records)
used to fail this way and now works.

To stay clear of it, the batch size is also capped by records:

- If a batch's tree has more than `max_batch_records` records, **before any hook runs** the roots are split in
  half and each half is run as its own batch (its own transaction), recursively. Everything still fires once;
  you just get more, smaller batches. Splitting is not atomic across parts: wrap the call in your own
  `transaction` if you need all-or-nothing.
- Targets of `belongs_to ..., dependent:` (the nested pass) are split the same way, within the same transaction.
- If a **single root's** tree alone exceeds the cap it cannot be split. By default
  `BulkDestroyer::TreeTooLarge` is raised, before any hook runs and with nothing deleted. With
  `oversized_tree = :inline` that batch runs its hooks without Fibers instead (its `after_destroy` hooks then run
  before the DELETE).
- The cap is per batch. Nested `belongs_to` batches run while the outer batch's remaining Fibers are still
  paused, so keep `max_batch_records` well under half of the ceiling. The default of 10,000 does.
- `:inline` mode creates no Fibers and ignores the cap.

A paused Fiber has no timeout in Ruby or Rails; what stays open meanwhile is the database transaction, so the
usual database and request timeouts apply to the whole call.

## Testing

```
BULK_DESTROYER_DB=sqlite3|postgresql|trilogy|mysql2 bundle exec ruby -Itest test/bulk_destroyer_test.rb
BULK_DESTROYER_HOOK_MODE=inline ...   # run the suite in inline hook mode
```

## Benchmarks

`rake bench` seeds a large tree with `insert_all` (no callbacks; about 17 rows per post: comments, polymorphic likes,
taggings, a HABTM join row, `delete_all` and `nullify` children, a `has_one`, counter caches) and then runs three
strategies against identical, freshly seeded data:

- `Post.destroy_all` (stock)
- `Post.find_each(&:destroy)` (per-record loop)
- `Post.bulk_destroy_all`

It first asserts that all three leave the same rows behind and fire exactly the same hook calls, then asserts that
`bulk_destroy_all` issues at least 10x fewer queries and is faster. Size and database are configurable:
`BENCH_POSTS=1000 BENCH_COMMENTS=5 BULK_DESTROYER_DB=postgresql rake bench`. It is skipped by `rake test`. 
The same file also has a test that destroys the 35,700-record tree described
under [The Fiber ceiling](#the-fiber-ceiling-and-max_batch_records) with default settings.

Single runs on a small cloud VM, Rails 8.1.3.1, Ruby 3.4.8, database on the same machine:

| Database | Posts / rows | Strategy | Seconds | Queries | Hook calls | Speedup |
|---|---|---|---|---|---|---|
| SQLite (in-memory) | 1,000 / 17,003 | `destroy_all` | 9.44 | 32,001 | 84,000 | 1.0x |
| | | `find_each(&:destroy)` | 9.25 | 32,002 | 84,000 | 1.0x |
| | | `bulk_destroy_all` | 1.34 | 45 | 84,000 | 7.1x |
| SQLite (in-memory) | 5,000 / 85,003 | `destroy_all` | 58.33 | 160,001 | 420,000 | 1.0x |
| | | `find_each(&:destroy)` | 56.76 | 160,006 | 420,000 | 1.0x |
| | | `bulk_destroy_all` | 6.69 | 221 | 420,000 | 8.7x |
| PostgreSQL 16 (TCP) | 1,000 / 17,003 | `destroy_all` | 19.73 | 32,001 | 84,000 | 1.0x |
| | | `find_each(&:destroy)` | 20.57 | 32,002 | 84,000 | 1.0x |
| | | `bulk_destroy_all` | 1.58 | 45 | 84,000 | 12.5x |

What the numbers say: the speedup comes from removing queries, and the callbacks themselves still cost the same
(84,000 hook calls either way), so the gap is smallest on an in-memory database and larger when each query costs
a round trip. I only measured a database on the same machine; I would expect a remote database to widen the gap
but have not measured it. `destroy_all` and `find_each(&:destroy)` are equivalent in cost, since both issue the
same per-record queries; the loop only avoids loading every record at once.

## Compatibility

Supports Rails **7.1 through 8.2** (`activerecord >= 7.1, < 8.3`) on Ruby **3.2 and newer**. The suite
(49 tests, foreign keys enforced) passes unchanged on:

| Rails | SQLite 3 | PostgreSQL 16 | MariaDB 10.11 |
|---|---|---|---|
| 7.1.6 | pass | not run | not run |
| 7.2.4 | pass | not run | not run |
| 8.0.5 | pass | not run | not run |
| 8.1.3.1 | pass | pass  | not run |
| 8.2.0.alpha (main) | pass | pass (first 22 tests only) | pass (first 22 tests only) |

CI runs the suite on SQLite for Ruby 3.2, 3.3 and 3.4 against Rails 7.1, 7.2, 8.0 and 8.1. Ruby 3.1 and
Rails 8.2 are not in the CI matrix. Other adapters (MySQL, Oracle, SQL Server) use the same ActiveRecord
APIs and have adapter-specific IN-list limits built in, but nothing has been run on Oracle or SQL Server.
Results from other databases are welcome.

**Rails 7.0 and earlier are not supported.** In 7.0 the connection lock is held by the calling fiber for the
whole transaction, so any hook that runs a query inside a hook Fiber raises
`ThreadError: deadlock; lock already owned by another fiber`. Rails 7.1 changed that locking. On 7.0,
`BulkDestroyer.hook_mode = :inline` avoids Fibers (in an earlier 22-test run, 20 passed; the other two assert
the post-DELETE `after_destroy` timing that inline mode intentionally gives up), but this is not a supported
configuration.

Version differences handled internally: `Model.with_connection` (7.2+, falls back to `connection` on 7.1) and
`counter_cached_association_names` (7.2+, falls back to the `belongs_to` reflections on 7.1).