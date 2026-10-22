# Changelog

## 0.1.0 - 2026-10-22

- Initial release: `bulk_destroy_all` and `bulk_destroy!`.
- Fires all destroy callbacks (including children's) with set-based SQL; `after_destroy` runs after the bulk DELETE (Fiber mode).
- Supports `dependent:` :destroy, :delete_all, :nullify, restrict_*, has_many :through, HABTM, and `belongs_to` :destroy/:delete.
- `max_batch_records` / `oversized_tree` guard against the Fiber ceiling.
- Rails 7.1 - 8.2, any ActiveRecord adapter (tested on SQLite and PostgreSQL).
