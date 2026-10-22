# frozen_string_literal: true

module BulkDestroyer
  # Rails implements `dependent:` as a before_destroy/after_destroy lambda that calls
  # association.handle_dependency, which loads and destroys children one by one. While a record
  # is being handled by BulkDestroyer we handle every dependent: mode ourselves, so the owner's
  # own callback must do nothing. Records not flagged behave exactly as in stock Rails.
  module CascadeGuard
    FLAG = :@__bulk_destroying

    def handle_dependency
      return if owner.instance_variable_get(FLAG)

      super
    end
  end
end
