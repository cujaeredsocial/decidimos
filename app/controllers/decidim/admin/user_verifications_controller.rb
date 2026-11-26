# frozen_string_literal: true

module Decidim
  module Admin
    # Manual identity verification by admins (Admin > Participants >
    # Account verification). Grants or revokes the "verified_account"
    # authorization, the same one participants get by signing in to EnZona.
    #
    # Only confirmed accounts are listed: confirmation (registered user)
    # comes first, see UserConfirmationsController.
    #
    # Mirrors Decidim::Admin::OfficializationsController (layout, menu,
    # permissions) like UserConfirmationsController.
    class UserVerificationsController < Decidim::Admin::ApplicationController
      include Decidim::Paginable

      WORKFLOW = DecidimCujae::VerifiedAccount::WORKFLOW
      STATES = %w(pending verified).freeze

      layout "decidim/admin/users"

      helper_method :search_term, :state, :authorizations_by_user

      add_breadcrumb_item_from_menu :admin_user_menu

      def index
        enforce_permission_to :read, :officialization

        @users = paginate(filtered_users.order(created_at: :desc))
      end

      def update
        enforce_permission_to :create, :officialization

        user = verifiable_users.find(params[:id])

        DecidimCujae::VerifiedAccount::GrantVerification.call(user:, verification_method: "manual", performed_by: current_user)

        redirect_to user_verifications_path(q: search_term.presence, state:),
                    notice: t("decidim.admin.user_verifications.update.success", name: user.name)
      end

      def destroy
        enforce_permission_to :create, :officialization

        user = verifiable_users.find(params[:id])
        authorization = Decidim::Authorization.find_by!(user:, name: WORKFLOW)

        Decidim.traceability.perform_action!("unverify", user, current_user) do
          authorization.destroy!
        end

        redirect_to user_verifications_path(q: search_term.presence, state:),
                    notice: t("decidim.admin.user_verifications.destroy.success", name: user.name)
      end

      private

      def search_term
        params[:q].to_s.strip
      end

      def state
        STATES.include?(params[:state]) ? params[:state] : "pending"
      end

      # Confirmed, self-registered, active accounts.
      def verifiable_users
        current_organization.users
                            .not_deleted
                            .not_blocked
                            .where(managed: false)
                            .where.not(confirmed_at: nil)
      end

      def granted_user_ids
        Decidim::Authorization.where(name: WORKFLOW).where.not(granted_at: nil).select(:decidim_user_id)
      end

      def filtered_users
        scope = verifiable_users
        scope = state == "verified" ? scope.where(id: granted_user_ids) : scope.where.not(id: granted_user_ids)
        return scope if search_term.blank?

        term = "%#{ActiveRecord::Base.sanitize_sql_like(search_term)}%"
        scope.where(
          "decidim_users.name ILIKE :term OR decidim_users.nickname ILIKE :term OR decidim_users.email ILIKE :term",
          term:
        )
      end

      def authorizations_by_user
        @authorizations_by_user ||= Decidim::Authorization
                                    .where(name: WORKFLOW, decidim_user_id: @users.map(&:id))
                                    .where.not(granted_at: nil)
                                    .index_by(&:decidim_user_id)
      end
    end
  end
end
