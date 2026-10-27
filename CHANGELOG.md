# Changelog

## 0.1.1 - 2026-10-27

- Fix: `bulk_destroy_all` on a `has_many :through` / HABTM collection (for example
  `course.students.bulk_destroy_all`) now raises `UnsupportedAssociation` instead of destroying the
  far-side records. Use `course.enrollments.bulk_destroy_all` to remove only the join rows, or
  `Student.where(...).bulk_destroy_all` to destroy the students. 0.1.0 on RubyGems did not include this
  guard; upgrade if you use it.

## 0.1.0 - 2026-10-22 [YANKED]

- Initial release: `bulk_destroy_all` and `bulk_destroy!`.
- Fires all destroy callbacks (including children's) with set-based SQL; `after_destroy` runs after the bulk DELETE (Fiber mode).
- Supports `dependent:` :destroy, :delete_all, :nullify, restrict_*, has_many :through, HABTM, and `belongs_to` :destroy/:delete.
- `max_batch_records` / `oversized_tree` guard against the Fiber ceiling.
- Rails 7.1 - 8.2, tested on SQLite and PostgreSQL.
