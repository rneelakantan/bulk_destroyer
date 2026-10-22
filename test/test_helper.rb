# frozen_string_literal: true

# Lets the suite run against a Rails checkout / custom load path (set BULK_DESTROYER_ENV to a file that prepares $LOAD_PATH).
require ENV["BULK_DESTROYER_ENV"] if ENV["BULK_DESTROYER_ENV"]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "active_record"
require "bulk_destroyer"
require "minitest/autorun"

BulkDestroyer.hook_mode = ENV["BULK_DESTROYER_HOOK_MODE"].to_sym if ENV["BULK_DESTROYER_HOOK_MODE"]

# BULK_DESTROYER_DB=sqlite3 (default) | postgresql | mysql2 | trilogy
case ENV.fetch("BULK_DESTROYER_DB", "sqlite3")
when "sqlite3"
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
else
  ActiveRecord::Base.establish_connection(
    adapter: ENV.fetch("BULK_DESTROYER_DB"), database: "bd_test", username: "bd", password: "bd",
    host: ENV.fetch("BULK_DESTROYER_HOST", "127.0.0.1")
  )
end
ActiveRecord::Schema.verbose = false
ActiveRecord::Base.connection.tables.each { |t| ActiveRecord::Base.connection.drop_table(t, force: :cascade) }

# Foreign keys are enforced by SQLite here, which is what proves the deletion order is valid.
ActiveRecord::Schema.define do
  create_table(:authors) { |t| t.string :name; t.integer :comments_count, default: 0, null: false; t.integer :posts_count, default: 0, null: false }
  create_table(:posts) do |t|
    t.references :author, foreign_key: true
    t.string :title
    t.integer :comments_count, default: 0, null: false
  end
  create_table(:comments) do |t|
    t.references :post, foreign_key: true, null: false
    t.references :author, foreign_key: true
    t.string :body
  end
  create_table(:likes) { |t| t.string :likeable_type; t.integer :likeable_id }
  create_table(:tags) { |t| t.string :name }
  create_table(:taggings) { |t| t.references :post, foreign_key: true; t.references :tag, foreign_key: true }
  create_table(:labels) { |t| t.string :name }
  create_table(:labels_posts, id: false) { |t| t.references :post, foreign_key: true; t.references :label, foreign_key: true }
  create_table(:audits) { |t| t.references :post, foreign_key: true }
  create_table(:notes) { |t| t.references :post, foreign_key: true, null: true }
  create_table(:details) { |t| t.references :post, foreign_key: true }
  create_table(:categories) { |t| t.references :parent, foreign_key: { to_table: :categories }; t.string :name }
  create_table(:vaults) { |t| t.references :author, foreign_key: true }
  # delegated_type style: polymorphic belongs_to with dependent: :destroy, deliberately without a DB foreign key
  create_table(:messages) { |t| t.string :body }
  create_table(:clips) { |t| t.references :message, foreign_key: true }
  create_table(:entries) { |t| t.string :entryable_type; t.integer :entryable_id }
  # two models that destroy each other
  create_table(:memos) { |t| t.string :body }
  create_table(:slots) { |t| t.string :holder_type; t.integer :holder_id }
  # belongs_to dependent: :delete (target has a real foreign key pointing at it)
  create_table(:snippets) { |t| t.string :body }
  create_table(:tickets) { |t| t.references :snippet, foreign_key: true }
  # has_many :through with dependent: on the through association itself
  create_table(:courses) { |t| t.string :name }
  create_table(:students) { |t| t.string :name }
  create_table(:enrollments) { |t| t.references :course, foreign_key: true; t.references :student, foreign_key: true }
  # polymorphic has_many dependent: :delete_all / :nullify (two target classes whose ids can collide)
  create_table(:gadgets) { |t| t.string :name }
  create_table(:gizmos) { |t| t.string :name }
  create_table(:reactions) { |t| t.string :target_type; t.integer :target_id }
  create_table(:marks) { |t| t.string :target_type; t.integer :target_id }
end

LOG = []

module Loggable
  class << self
    attr_accessor :probe, :explode_in, :rollback_in, :rollback_title
  end

  def self.included(base)
    base.before_destroy do
      if Loggable.rollback_in == self.class.name && (Loggable.rollback_title.nil? || try(:title) == Loggable.rollback_title)
        raise ActiveRecord::Rollback
      end
    end
    base.before_destroy { LOG << [:before, self.class.name, id] }
    base.around_destroy :log_around
    base.after_destroy { LOG << [:after, self.class.name, id, (Loggable.probe ? self.class.base_class.unscoped.exists?(id) : nil)] }
    base.after_commit(on: :destroy) { LOG << [:commit, self.class.name, id] }
    base.after_destroy { raise "boom" if Loggable.explode_in == self.class.name }
  end

  def log_around
    LOG << [:around_pre, self.class.name, id]
    yield
    LOG << [:around_post, self.class.name, id]
  ensure
    LOG << [:around_ensure, self.class.name, id]
  end
end

class Author < ActiveRecord::Base
  has_many :posts, dependent: :destroy
  has_many :vaults, dependent: :restrict_with_exception
end

class Vault < ActiveRecord::Base
  belongs_to :author
end

class Post < ActiveRecord::Base
  include Loggable
  belongs_to :author, counter_cache: true, optional: true
  has_many :comments, dependent: :destroy
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings
  has_and_belongs_to_many :labels
  has_many :likes, as: :likeable, dependent: :destroy
  has_many :audits, dependent: :delete_all
  has_many :notes, dependent: :nullify
  has_one :detail, dependent: :destroy
end

class Comment < ActiveRecord::Base
  include Loggable
  belongs_to :post, counter_cache: true
  belongs_to :author, counter_cache: true, optional: true
  has_many :likes, as: :likeable, dependent: :destroy
  before_destroy(if: -> { body == "run" }) { LOG << [:conditional_ran, id] }
  after_destroy { LOG << [:parent_present, Post.unscoped.exists?(post_id)] if Loggable.probe }
  before_destroy { throw :abort if body == "abort" }
end

class Like < ActiveRecord::Base
  include Loggable
  belongs_to :likeable, polymorphic: true
end

class Tag < ActiveRecord::Base
  has_many :taggings
end

class Tagging < ActiveRecord::Base
  include Loggable
  belongs_to :post
  belongs_to :tag
end

class Label < ActiveRecord::Base
  has_and_belongs_to_many :posts
end

class Audit < ActiveRecord::Base
  belongs_to :post
end

class Note < ActiveRecord::Base
  belongs_to :post, optional: true
end

class Detail < ActiveRecord::Base
  include Loggable
  belongs_to :post
end

class Category < ActiveRecord::Base
  include Loggable
  belongs_to :parent, class_name: "Category", optional: true
  has_many :children, class_name: "Category", foreign_key: :parent_id, dependent: :destroy
end

class Message < ActiveRecord::Base
  include Loggable
  has_many :clips, dependent: :destroy
  before_destroy { throw :abort if body == "abort" }
end

class Clip < ActiveRecord::Base
  include Loggable
  belongs_to :message
end

class Entry < ActiveRecord::Base
  include Loggable
  # what `delegated_type :entryable, types: %w[Message], dependent: :destroy` declares
  belongs_to :entryable, polymorphic: true, dependent: :destroy
end

class Memo < ActiveRecord::Base
  include Loggable
  has_one :slot, as: :holder, dependent: :destroy
end

class Slot < ActiveRecord::Base
  include Loggable
  belongs_to :holder, polymorphic: true, dependent: :destroy
end

class Snippet < ActiveRecord::Base
end

class Course < ActiveRecord::Base
  has_many :enrollments
  has_many :students, through: :enrollments, dependent: :destroy
end

class Student < ActiveRecord::Base
  has_many :enrollments
end

class Enrollment < ActiveRecord::Base
  include Loggable
  belongs_to :course
  belongs_to :student
end

class Gadget < ActiveRecord::Base
  has_many :reactions, as: :target, dependent: :delete_all
  has_many :marks, as: :target, dependent: :nullify
end

class Gizmo < ActiveRecord::Base
end

class Reaction < ActiveRecord::Base
  belongs_to :target, polymorphic: true
end

class Mark < ActiveRecord::Base
  belongs_to :target, polymorphic: true
end

class Ticket < ActiveRecord::Base
  include Loggable
  belongs_to :snippet, dependent: :delete
end

# Records the most Fibers any single batch had paused at the same time.
module PausedFiberSpy
  class << self
    attr_accessor :max
  end

  def start(record)
    result = super
    PausedFiberSpy.max = [PausedFiberSpy.max.to_i, @fibers.size].max
    result
  end
end
BulkDestroyer::HookRunner::FiberRunner.prepend(PausedFiberSpy)

class BulkDestroyerTest < Minitest::Test
  TABLES = %w[likes comments taggings labels_posts audits notes details posts vaults authors tags labels categories
              clips entries messages slots memos tickets snippets enrollments students courses reactions marks gadgets gizmos].freeze

  def setup
    TABLES.each { |t| ActiveRecord::Base.connection.execute("DELETE FROM #{t}") }
    LOG.clear
    Loggable.probe = false
    Loggable.explode_in = nil
    Loggable.rollback_in = nil
    Loggable.rollback_title = nil
    PausedFiberSpy.max = 0
  end

  def with_config(**options)
    old = options.keys.to_h { |key| [key, BulkDestroyer.public_send(key)] }
    options.each { |key, value| BulkDestroyer.public_send("#{key}=", value) }
    yield
  ensure
    old.each { |key, value| BulkDestroyer.public_send("#{key}=", value) }
  end

  def events(kind, klass = nil)
    LOG.select { |e| e[0] == kind && (klass.nil? || e[1] == klass) }
  end

  def count_queries
    n = 0
    counter = lambda do |*, payload|
      sql = payload[:sql]
      n += 1 unless payload[:name] == "SCHEMA" || sql =~ /\A\s*(SAVEPOINT|RELEASE|BEGIN|COMMIT|ROLLBACK)/i
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    n
  end

  # A post with a child in every kind of dependent: association.
  def build_post(author: nil, comments: 2)
    post = Post.create!(title: "p", author: author)
    comments.times do
      c = Comment.create!(post: post, author: author, body: "x")
      Like.create!(likeable: c)
    end
    Like.create!(likeable: post)
    tag = Tag.create!(name: "t")
    Tagging.create!(post: post, tag: tag)
    post.labels << Label.create!(name: "l")
    Audit.create!(post: post)
    Note.create!(post: post)
    Detail.create!(post: post)
    post
  end
end
