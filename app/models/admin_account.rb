class AdminAccount < ApplicationRecord
  has_secure_password
  has_many :admin_sessions, dependent: :destroy
  normalizes :username, with: ->(value) { value.strip.downcase }
  validates :username, presence: true, uniqueness: true, length: { maximum: 80 }, format: { with: /\A[a-z0-9._-]+\z/ }
  validates :password, length: { minimum: 6 }, allow_nil: true
  def api_json
    { username: username }
  end
end
