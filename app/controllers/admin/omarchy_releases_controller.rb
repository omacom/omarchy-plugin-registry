module Admin
  class OmarchyReleasesController < BaseController
    def index
      @release = OmarchyRelease.new
      @releases = OmarchyRelease.order(created_at: :desc).limit(200)
    end

    def create
      attributes = params.expect(omarchy_release: [ :version, :build, :channel, apis: [ plugin: [], theme: [] ] ]).to_h
      attributes["apis"] = attributes.fetch("apis", {}).transform_values do |values|
        values.map { |v| v.to_s.match?(/\A[1-9]\d{0,4}\z/) ? v.to_i : v }
      end
      @release = OmarchyRelease.new(attributes)
      OmarchyRelease.transaction do
        @release.save!
        AuditEvent.record!(actor: Current.user, action: "compatibility.release", subject: @release, public: true, metadata: @release.entry)
      end
      DataPlane::RegenerateJob.perform_later
      redirect_to admin_omarchy_releases_path, status: :see_other, notice: "Release contract registered."
    rescue ActiveRecord::RecordInvalid
      @releases = OmarchyRelease.order(created_at: :desc).limit(200)
      render :index, status: :unprocessable_entity
    end
  end
end
