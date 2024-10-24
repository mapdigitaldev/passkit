module Passkit
  class Registration < ::ApplicationRecord
    belongs_to :device, foreign_key: :passkit_device_id
    belongs_to :pass, foreign_key: :passkit_pass_id
  end
end
