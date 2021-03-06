class SapExport < ApplicationRecord

	def self.can_create? u, *args; false; end

	has_many :sales
	has_many :sap_lines
	
	def label; created_at.dt; end
	
	POSTING_DATE_DELAY = 2
	
	# Run cron at like 1am and it will export all for previous day.
	def self.cron
		logger.info "Start SapExport Cron #{Time.now}"
		run_and_push Date.today - 1
		logger.info "Done SapExport Cron #{Time.now}"
	end
	
	# date - cutoff date for transactions (inclusive)
	# ts - saved timestamp of date run/created
	def self.run_and_push date, ts = nil
		e = run(date, ts)
		e.push_file
	end
	
	def push_file
		logger.info "Pushing SapExport ID #{id} #{Time.now}"
		if false 
			ftp = Net::FTP.new '10.100.224.234'
			ftp.login 'sapsp', 'Fall2017'
			tmp = Tempfile.new('hd-sap-export')
			tmp.write(data)
			tmp.close
			ftp.puttextfile(tmp.path, data_file_name)
			ftp.close
		end
		logger.info "Done Pushing SapExport #{id} #{Time.now}"
	end
	
	def data_file_name
		e = Rails.env.development? ? 'dev' : 'pro'
		ts = created_at.strftime('%Y%m%d')
		"export-hd-#{e}-#{ts}.txt"
	end
	
	def self.run date = nil, ts = nil
		holidays ||= Holiday.all.index_by(&:date) # Limit this to reasonable date range? Funeral activity can hypothetically go way back though...
		date ||= Date.today
		export = SapExport.create :created_at => ts || Time.now, :cutoff_date => date
		logger.info "Creating SapExport #{export.id} #{date}"
		# Rails generated aliases for where condition:
		# sale_details <-- select from
		# sales <-- transaction
		# payments_sale_details <-- transaction record of the payment
		SaleDetail.eager_load(:sale, :payment).where(
			# Forget about zero dollar noise and stuff that's in the future (after the export date)
			'sale_details.amount != 0 and date(sales.date) <= ? and sale_details.type in ("Sale", "Invoice", "Payment", "Refund", "AR Refund") and ' +
			# Include everything that hasn't been exported yet
			'(sale_details.sap_line_id is null or ' +
			# Or has a payment but the payment_id hasn't been sent to SAP yet. Also make sure the payment isn't in the future
			'(sale_details.payment_id is not null and sale_details.pay_sap_line_id is null and date(payments_sale_details.date) <= ?))',
			date, date
		).each { |detail|
			transaction = detail.sale
			payment_detail = detail.payment
			logger.info "Export SaleDetail ID: #{detail.id} SaleID: #{detail.sale_id} Type: #{detail.type}"		
			posting_date = transaction.date
			if !detail.invoice? && (detail.pay_cash? || detail.pay_check? || detail.pay_cc?)
				posting_date -= 1
				0.upto(POSTING_DATE_DELAY) { |i|
					loop {
						posting_date += 1 
						if detail.pay_cc?
							# Skip sundays, skip saturdays & holidays only if its the last day.
							break if !(posting_date.sunday? || ((posting_date.saturday? || holidays[posting_date]) && i == POSTING_DATE_DELAY))
						else
							# Skip sundays, skip saturdays, skip holidays. This could still be wrong.
							break if !(posting_date.sunday? || posting_date.saturday? || holidays[posting_date])
						end
					}
				}
			end
			h = {
				cost_center: ((transaction.division == "immunization").present? ? '5802050100' : (transaction.division == "tb").present? ? '5802020000' : ''),			
				credit: '405000',
				debit: (detail.pay_cc? ? '114040' : (detail.pay_check? ? '100013' : '100013')),
				amount: detail.amount,
				document_header: detail.payment? || detail.sale? || detail.refund? ? (
					detail.pay_cc? ? "#{posting_date.strftime('%m/%d/%Y')} EBS CLEARING" : (detail.pay_cash_check? ? 'Deposit 4' : (detail.pay_credit? ? 'Refund' : ''))
				) : '',
				posting_date: posting_date,
				reference_key2: nil
			}
			if detail.invoice? || detail.payment? || detail.ar_refund? # Use AR SAP Transfer
				ref3 = 'EH ITEM'
				if detail.payment?
					ref3 = detail.pay_cc? ? 'EH CREDIT' : (detail.pay_check? ? 'EH CHECK' : (detail.pay_cash? ? 'EH CASH' : (detail.pay_credit? ? 'EH REFUND' : '')))
				elsif detail.ar_refund?
					ref3 = 'EH REVERSE CASH'
				end
				if detail.invoice?
					text = detail.item_name_short.presence || detail.item_description.presence || detail.item_info.presence || ''
				else
					text = transaction.memo.to_s
				end
				if detail.split && (detail.payment? || detail.ar_refund?)
					text = "SPLIT FROM #{transaction.id}"
				end				
				if !detail.invoice? && detail.pay_check? && !transaction.check_no.blank?
					text = "#{transaction.check_no} #{text}"
				end
				h += {
					reference: detail.id,
					reference_key1: payment_detail&.id,
					resent: !!detail.sap_line_id,
					text: text,
					assignment: 'EH Accounts',
					reference_key3: ref3,
					invoice_date: transaction.date,
					customer: transaction.customer_id
				}
				if h.amount < 0
					ref3 = 'EH REFUND'
					if detail.payment?
						ref3 = detail.payment.pay_credit? ? 'EH ITEM' : 'EH REVERSE CASH'
					elsif detail.ar_refund?
						ref3 = detail.pay_cc? ? 'EH CREDIT' : (detail.pay_check? ? 'EH CHECK' : (detail.pay_cash? ? 'EH CASH' : ''))
					end
					h[:debit], h[:credit] = h.credit, h.debit
					h[:amount] *= -1
					h[:reference_key3] = ref3
				end				
			else # sales or refund use sales SAP transfer
				if detail.sale?
					text = detail.item_name_short.presence || detail.item_description.presence || detail.item_info.presence || ''
				else
					text = transaction.memo.to_s
				end
				if detail.pay_check? && !transaction.check_no.blank?
					text = "#{transaction.check_no} #{text}"
				end			
				h += {
					reference: detail.pay_cc? ? '2645' : '',
					reference_key1: transaction.id.to_s + detail.document_letter.to_s,
					resent: nil,
					text: text,
					assignment: (detail.pay_cc? ? 'CLINIC CREDIT' : (detail.pay_check? ? 'CLINIC CHECK' : 'CLINIC CASH')),
					reference_key3: detail.refund? ? '' : 'Shot',
					invoice_date: transaction.date,
					customer: nil
				}
				if h.amount < 0
					h[:debit], h[:credit] = h.credit, h.debit
					h[:amount] *= -1
				end
			end
			line = export.sap_lines.create(h)
			line.save
			detail.sap_line_id = line.id if !detail.sap_line_id
			detail.pay_sap_line_id = line.id if payment_detail
			detail.save
		}
		export.data = export.sap_lines.map(&:to_tab) * "\n"
		export.update_attribute :sap_lines_count, export.sap_lines.length
		logger.info "Done Building SapExport #{export.id}"
		return export
	end
	
	def self.clear_exports
		DB.query 'truncate table sap_exports'
		DB.query 'truncate table sap_lines'
		DB.query 'update sale_details set sap_line_id = null, pay_sap_line_id = null'
	end
	
	def self.initialize_exports
		before = '2019-03-01'
		DB.query 'update sale_details d join sales t on t.id = d.sale_id set d.sap_line_id = 0, d.pay_sap_line_id = 0 where date(created_at) < ?', before
	end
	
	def self.create_test_days
		from = Date.new 2019, 2, 1
		to = Date.today
		(from..to).each { |d|
			SapExport.run_and_push d, (d + 1).change(hour: 2)
		}
	end
	
	def self.clear_init_create_test
		puts "Cron job is running.."
		self.clear_exports
		self.initialize_exports
		self.create_test_days
	end

end