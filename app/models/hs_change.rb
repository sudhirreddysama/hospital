class HsChange < ApplicationRecord

	belongs_to :obj, :polymorphic => true
	
	belongs_to :user
	
	serialize :values, JSON

	def label; created_at_was.dt; end

	def self.can_create? u, *args; false; end

	module Track

		extend ActiveSupport::Concern
		
		def save_hs_change action, vals = []
			vals.reject! { |k, v| 
				(v[0].blank? && v[1].blank?) || (v[0] == v[1])
			}
			return if vals.empty?
			HsChange.create({
				user: current_user,
				action: action,
				obj: self,
				values: vals
			})
		end
 	
		included {
			has_many :hs_changes, as: :obj
			after_create { save_hs_change 'new', changes }
			before_update { save_hs_change 'edit', changes }
			before_destroy { save_hs_change 'delete', attributes.transform_values { |v| [v, nil] } }
		}
	end

end