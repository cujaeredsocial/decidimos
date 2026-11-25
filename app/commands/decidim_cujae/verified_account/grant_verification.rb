# frozen_string_literal: true

module DecidimCujae
  module VerifiedAccount
    # Grants the "verified_account" authorization to a participant.
    #
    # Broadcasts:
    #   :ok           - granted (or already granted, which is left untouched)
    #   :already_used - unique_id already verifies another account of the org
    #   :invalid      - unknown method
    class GrantVerification < Decidim::Command
      # user         - Decidim::User to verify
      # verification_method - "enzona" or "manual"
      # unique_id    - EnZona subject id (nil for manual)
      # performed_by - admin Decidim::User for the admin log (nil for self-service)
      def initialize(user:, verification_method:, unique_id: nil, performed_by: nil)
        @user = user
        @verification_method = verification_method.to_s
        @unique_id = unique_id.presence
        @performed_by = performed_by
      end

      def call
        return broadcast(:invalid) unless METHODS.include?(verification_method)
        return broadcast(:already_used) if duplicate?
        return broadcast(:ok) if authorization.granted?

        authorization.unique_id = unique_id
        authorization.metadata = { "method" => verification_method }

        if performed_by
          Decidim.traceability.perform_action!("verify", user, performed_by) { authorization.grant! }
        else
          authorization.grant!
        end

        broadcast(:ok)
      end

      private

      attr_reader :user, :verification_method, :unique_id, :performed_by

      def authorization
        @authorization ||= Decidim::Authorization.find_or_initialize_by(user:, name: WORKFLOW)
      end

      def duplicate?
        return false if unique_id.blank?

        Decidim::Authorization
          .joins(:user)
          .where(name: WORKFLOW, unique_id:)
          .where(decidim_users: { decidim_organization_id: user.decidim_organization_id })
          .where.not(decidim_user_id: user.id)
          .exists?
      end
    end
  end
end
