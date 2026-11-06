require 'digest'
class AdminSession < ApplicationRecord
  belongs_to :admin_account
  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  COOKIE = 'saiko_admin_session'.freeze
  def self.from_token(token)
    return if token.blank? || token.bytesize > 256
    includes(:admin_account).where('expires_at > ?', Time.current).find_by(token_digest: Digest::SHA256.hexdigest(token))
  end
end
