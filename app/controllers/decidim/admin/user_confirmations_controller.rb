# frozen_string_literal: true

module Decidim
  module Admin
    # Manual account verification while the platform has no mail server.
    #
    # Lists the participants who registered but never confirmed their email
    # and lets an admin confirm them, which unblocks their sign in (Devise
    # `allow_unconfirmed_access_for` is 0 in Decidim, so unconfirmed users
    # cannot log in).
    #
    # Mirrors Decidim::Admin::OfficializationsController (layout, menu,
    # permissions) so it lives under Admin > Participants.
    class UserConfirmationsController < Decidim::Admin::ApplicationController
      include Decidim::Paginable

      layout "decidim/admin/users"

      helper_method :search_term

      add_breadcrumb_item_from_menu :admin_user_menu

      def index
        enforce_permission_to :read, :officialization

        @users = paginate(filtered_users.order(created_at: :desc))
      end

      def update
        enforce_permission_to :create, :officialization

        user = pending_users.find(params[:id])

        Decidim.traceability.perform_action!("confirm", user, current_user) do
          user.confirm
        end

        redirect_to user_confirmations_path(q: search_term.presence),
                    notice: t("decidim.admin.user_confirmations.update.success", name: user.name)
      end

      private

      def search_term
        params[:q].to_s.strip
      end

      # Self-registered users only: managed (impersonated) users and pending
      # invitations have their own flows and no password to log in with.
      def pending_users
        current_organization.users
                            .not_deleted
                            .not_confirmed
                            .where(managed: false, invitation_token: nil)
      end

      def filtered_users
        return pending_users if search_term.blank?

        term = "%#{ActiveRecord::Base.sanitize_sql_like(search_term)}%"
        pending_users.where(
          "decidim_users.name ILIKE :term OR decidim_users.nickname ILIKE :term OR decidim_users.email ILIKE :term",
          term:
        )
      end
    end
  end
end
