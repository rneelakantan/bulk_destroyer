# frozen_string_literal: true

module BulkDestroyer
  module RelationMethods
    # Like #destroy_all: every destroy callback fires on every record, including dependent:
    # :destroy descendants. Unlike #destroy_all: one SELECT per association per level and one
    # DELETE per table per level.
    def bulk_destroy_all(batch_size: BulkDestroyer.batch_size)
      Destroyer.new(self, batch_size: batch_size).call
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
