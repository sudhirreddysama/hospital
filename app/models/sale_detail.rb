class SaleDetail < Record
	
	include Sale::Types
	
	delegate :pay_method, :pay_cc?, :pay_cash?, :pay_check?, :pay_credit?, :pay_cash_check?, :pay_cash_check_cc?, to: :sale
	
	self.inheritance_column = nil
	
	def self.can_create? u, *args; false; end
	
	def label; "Transaction Detail #{id}"; end
	
	belongs_to :sale
	belongs_to :shot
	belongs_to :sap_line
	has_one :sap_export, through: :sap_line
	belongs_to :pay_sap_line, class_name: 'SapLine'
	has_one :pay_sap_export, through: :pay_sap_line, source: :sap_export
	belongs_to :payment, class_name: 'Sale'
	belongs_to :customer
	
	# previous points to the sale_detail it is refunding
	belongs_to :previous, class_name: 'SaleDetail'
	
	# refunded_by points to the sale_details that have refunded it - there may be more than 1
	has_many :refunded_by, class_name: 'SaleDetail', foreign_key: :previous_id
	
	belongs_to :qb_multi_invoice_detail
	belongs_to :qb_late_fee
	
	belongs_to :qb_debit_ledger, class_name: 'HsLedger', foreign_key: :debit_ledger, primary_key: :code
	belongs_to :qb_credit_ledger, class_name: 'HsLedger', foreign_key: :credit_ledger, primary_key: :code	
	belongs_to :costcenter, foreign_key: :cost_center, primary_key: :code
	
	belongs_to :qb_late_fee_document, class_name: 'Document'
	
	scope :payable, -> { where 'amount != 0 and voided = 0 and type in ("Invoice", "Payment", "AR Refund")' }
	scope :needs_payment, -> { payable.where payment_id: nil }
	
	def sap_or_pay_lock?
		sap_line_id || payment_id
	end
	
	def sap_or_pay_or_late_fee_delivery_lock?
		sap_or_pay_lock? || qb_late_fee_document&.doc_delivery_id
	end
	
	# Only the last part of the item name
	def item_name_short
		item_name.to_s.split(':').last
	end
	
end