require "digest"
class EnrollmentsController < ApplicationController
  rate_limit to: 10, within: 1.minute, only: :redeem, with: -> { render json: { success: false, error: "Too many enrollment attempts" }, status: :too_many_requests }
  def create
    code = SecureRandom.urlsafe_base64(24)
    device = find_device
    device.with_lock do
      device.update!(enrollment_digest: Digest::SHA256.hexdigest(code), enrollment_expires_at: 15.minutes.from_now)
    end
    success(enrollmentCode: code, expiresAt: device.enrollment_expires_at)
  end

  def redeem
    code = params.require(:enrollmentCode).to_s
    device = Device.find_by!(device_id: required_id)
    token = SecureRandom.urlsafe_base64(48)
    device.with_lock do
      valid = device.enrollment_expires_at&.future? && device.enrollment_digest.present? &&
        ActiveSupport::SecurityUtils.secure_compare(device.enrollment_digest, Digest::SHA256.hexdigest(code))
      return render(json: { success: false, error: "Invalid or expired enrollment code" }, status: :unauthorized) unless valid
      device.update!(credential_digest: Digest::SHA256.hexdigest(token), enrollment_digest: nil, enrollment_expires_at: nil)
    end
    response.headers["Cache-Control"] = "no-store"
    success(deviceToken: token)
  end

  def auth
    success(authenticated: true)
  end
end
