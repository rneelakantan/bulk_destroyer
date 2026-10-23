# frozen_string_literal: true

module BulkDestroyer
  module RelationMethods
    # Like #destroy_all: every destroy callback fires on every record, including dependent:
    # :destroy descendants. Unlike #destroy_all: one SELECT per association per level and one
    # DELETE per table per level.
    def bulk_destroy_all(batch_size: BulkDestroyer.batch_size)
      refuse_through_collection!
      Destroyer.new(self, batch_size: batch_size).call
    end

    private

    # `course.students.destroy_all` on a has_many :through (or HABTM) collection removes the join rows and
    # keeps the students. Running our relation-level destroy on that proxy would instead destroy the far-side
    # records themselves, so refuse it loudly rather than guess which one the caller meant.
    def refuse_through_collection!
      return unless is_a?(ActiveRecord::Associations::CollectionProxy)

      reflection = proxy_association.reflection
      return unless reflection.through_reflection?

      owner = proxy_association.owner.class.name
      raise UnsupportedAssociation,
            "#{owner}##{reflection.name} is a has_many :through collection. bulk_destroy_all would destroy the " \
            "#{reflection.klass.name} records themselves (Rails' own destroy_all removes only the join rows). " \
            "To remove the join rows call bulk_destroy_all on #{owner}##{reflection.through_reflection.name}; " \
            "to destroy the #{reflection.klass.name} records use #{reflection.klass.name}.where(...).bulk_destroy_all."
    end
  end

  module ClassMethods
    def bulk_destroy_all(batch_size: BulkDestroyer.batch_size)
      all.bulk_destroy_all(batch_size: batch_size)
    end
  end

  module RecordMethods
    def bulk_destroy!
      Destroyer.new(self).call
    end
  end
end
