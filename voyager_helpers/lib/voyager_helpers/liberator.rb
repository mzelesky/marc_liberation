require 'oci8'
require 'marc'
require_relative 'queries'
require_relative 'oracle_connection'

module VoyagerHelpers
  class Liberator
    class << self
      include VoyagerHelpers::Queries
      include VoyagerHelpers::OracleConnection

      # @param bib_id [Fixnum] A bib record id
      # @option opts [Boolean] :holdings (true) Include holdings?
      # @option opts [Boolean] :holdings_in_bib (true) Copy 852 fields to the bib record?
      # @return [MARC::Record] If `holdings: false` or there are no holdings.
      # @return [Array<MARC::Record>] If `holdings: true` (default) and there
      #   are holdings.
      def get_bib_record(bib_id, conn=nil, opts={})
        if conn.nil?
          connection do |c|
            unless bib_is_suppressed?(bib_id, c)
              if opts.fetch(:holdings, true)
                get_bib_with_holdings(bib_id, c, opts)
              else
                get_bib_without_holdings(bib_id, c)
              end
            end
          end
        else
          unless bib_is_suppressed?(bib_id, conn)
            if opts.fetch(:holdings, true)
              get_bib_with_holdings(bib_id, conn, opts)
            else
              get_bib_without_holdings(bib_id, conn)
            end
          end
        end
      end

      # @param mfhd_id [Fixnum] A holding record id
      # @return [MARC::Record]
      def get_holding_record(mfhd_id, conn=nil)
        if conn.nil?
          connection do |c|
            unless mfhd_is_suppressed?(mfhd_id, c)
              segments = get_mfhd_segments(mfhd_id, c)
              MARC::Reader.decode(segments.join(''), :external_encoding => "UTF-8", :invalid => :replace, :replace => '') unless segments.empty?
            end
          end
        else
          unless mfhd_is_suppressed?(mfhd_id, conn)
            segments = get_mfhd_segments(mfhd_id, conn)
            MARC::Reader.decode(segments.join(''), :external_encoding => "UTF-8", :invalid => :replace, :replace => '') unless segments.empty?
          end
        end
      end

      # @param bib_id [Fixnum] A bib record id
      # @return [Array<MARC::Record>]
      def get_holding_records(bib_id, conn=nil)
        records = []
        if conn.nil?
          connection do |c|
            get_bib_mfhd_ids(bib_id, c).each do |mfhd_id|
              record = get_holding_record(mfhd_id, c)
              records << record unless record.nil?
            end
          end
        else
          get_bib_mfhd_ids(bib_id, conn).each do |mfhd_id|
            record = get_holding_record(mfhd_id, conn)
            records << record unless record.nil?
          end
        end
        records
      end

      # strips invalid xml characters to prevent parsing errors
      # only used for "cleaning" individually retrieved records
      def valid_xml(xml_string)
        invalid_xml_range = /[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD]/
        xml_string.gsub(invalid_xml_range, '')
      end

      # @return [<Hash>]
      def get_item_statuses
        query = VoyagerHelpers::Queries.statuses
        statuses = {}
        connection do |c|
          c.exec(query) { |id,desc| statuses.store(id,desc) }
        end
        statuses
      end

      def get_items_for_holding(mfhd_id, conn=nil)
        if conn.nil?
          connection do |c|
            accumulate_items_for_holding(mfhd_id, c)
          end
        else
          accumulate_items_for_holding(mfhd_id, conn)
        end
      end

      def get_item(item_id, conn=nil)
        if conn.nil?
          connection do |c|
            get_info_for_item(item_id, c)
          end
        else
          get_info_for_item(item_id, conn)
        end
      end

      def get_locations
        query = VoyagerHelpers::Queries.all_locations
        locations = {}
        connection do |c|
          c.exec(query) do |id, code, display_name, suppress|
            locations[id] = {}
            locations[id][:code] = code
            locations[id][:display_name] = display_name
            locations[id][:suppress] = suppress
          end
        end
        locations
      end

      # This fires off quite a few queries; could probably be optimized
      def get_items_for_bib(bib_id)
        connection do |c|
          items = []
          any_items = false
          mfhds = get_holding_records(bib_id, c)
          mfhds.each do |mfhd|
            mfhd_hash = mfhd.to_hash
            mfhd_id = id_from_mfhd_hash(mfhd_hash)
            holding_items = get_items_for_holding(mfhd_id, c)
            unless holding_items.empty?
              any_items = true
              data = { holding_id: mfhd_id.to_i }
              # Everyone seems quite sure that we don't repeat 852 per mfhd
              field_852 = fields_from_marc_hash(mfhd_hash, '852').first['852']
              data[:perm_location] = location_from_852(field_852)
              data[:call_number] = callno_from_852(field_852)
              notes = holdings_notes_from_mfhd_hash(mfhd_hash)
              data[:notes] = notes unless notes.empty?
              data[:items] = []
              holding_items.each do |item|
                data[:items] << item
              end
              data[:items].sort_by! { |i| i[:item_sequence_number] }.reverse!
              items << data
            end
          end
          unless any_items
            orders = get_orders(bib_id, c)
            items << { perm_location: 'order', items: orders} unless orders.empty?
          end
          group_items(items)
        end
      end

      # @param bibs [Array<Fixnum>] Bib ids
      # @param full [Boolean] true return full availability for single bib, false (default) first 2 holdings
      # @return [Hash] :bib_id_value => [Hash] bib availability
      # 
      #
      # Bib availability hash:
      # For the bib's holding records:
      # :holding_id_value => [Hash] holding availability
      #
      # Holding availability hash:
      # :status => [String] Voyager item status for the first item.
      # :location => [String] Holding location code (mainly for debugging)
      # :more_items => [Boolean] Does the holding record have more than 1 item?
      def get_availability(bibs, full=false)
        number_of_mfhds = full ? 0..-1 : 0..1 # all vs first 2
        connection do |c|
          availability = {}
          bibs.each do |bib_id|
            availability[bib_id] = {}
            mfhds = get_holding_records(bib_id, c)
            mfhds[number_of_mfhds].each do |mfhd|
              mfhd_hash = mfhd.to_hash
              mfhd_id = id_from_mfhd_hash(mfhd_hash)
              field_852 = fields_from_marc_hash(mfhd_hash, '852').first['852']
              field_852 = location_from_852(field_852)
              holding_item_ids = get_item_ids_for_holding(mfhd_id, c)

              availability[bib_id][mfhd_id] = {} # holding record availability hash
              availability[bib_id][mfhd_id][:more_items] = holding_item_ids.count > 1
              availability[bib_id][mfhd_id][:location] = field_852

              availability[bib_id][mfhd_id][:status] = if holding_item_ids.empty?
                if !(order_status = get_order_status(bib_id)).nil?
                  order_status
                elsif field_852[/^elf/]
                  'Online'
                elsif limited_access_location?(field_852)
                  'Limited'
                else
                  'On Shelf'
                end
              else
                item = get_info_for_item(holding_item_ids.first, c, false)
                availability[bib_id][mfhd_id][:on_reserve] = item[:temp_location] || item[:perm_location] if item[:on_reserve] == 'Y'
                if limited_access_location?(field_852)
                  'Limited'
                else
                  item[:status]
                end
              end
            end
          end
          _, availability = availability.first if full # return just holding availability hash (single bib)
          availability
        end
      end

      # @param mfhd_id [Fixnum] get info for all mfhd items
      # @return [Array<Hash>] Item hash includes status, enumeration, reserve location code
      def get_full_mfhd_availability(mfhd_id)
        item_availability = []
        items = get_items_for_holding(mfhd_id)
        items.each do |item|
          item_hash = {}
          item_hash[:barcode] = item[:barcode]
          item_hash[:id] = item[:id]
          if item[:on_reserve] == 'Y'
            item_hash[:on_reserve] = item[:temp_location] || item[:perm_location]
            item_hash[:copy_number] = item[:copy_number]
            item_hash[:status] = item[:status]
          else
            item_hash[:status] = limited_access_location?(item[:perm_location]) ? 'Limited' : item[:status]
            item_hash[:copy_number] = item[:copy_number] if item[:copy_number] != 1
          end
          unless item[:enum].nil?
            enum = item[:enum]
            enum << " (#{item[:chron]})" unless item[:chron].nil?
            item_hash[:enum] = enum
          end
          item_availability << item_hash
        end
        item_availability
      end

      # @param mfhd_id [Fixnum] get current issues for mfhd
      # @return [Array<Hash>] Current issues
      def get_current_issues(mfhd_id)
        query = VoyagerHelpers::Queries.current_periodicals(mfhd_id)
        issues = []
        connection do |c|
          c.exec(query) do |enum|
            issues << enum.first
          end
        end
        issues
      end

      def dump_bibs_to_file(ids, file_name, opts={})
        writer = MARC::XMLWriter.new(file_name)
        connection do |c|
          ids.each do |id|
            r = VoyagerHelpers::Liberator.get_bib_record(id, c)
            writer.write(r) unless r.nil?
          end
        end
        writer.close()
      end

      # @param patron_id [String] Either a netID, PUID, or PU Barcode
      # @return [<Hash>]
      def get_patron_info(patron_id)
        id_type = determine_id_type(patron_id)
        query = VoyagerHelpers::Queries.patron_info(patron_id, id_type)
        connection do |c|
          exec_get_info_for_patron(query, c)
        end
      end

      # @param bib_id [Fixnum] Find order status for provided bib ID
      # @return [String] on-order status message and date of status if the status code in whitelist
      # if code is not whitelisted return nil
      def get_order_status(bib_id)
        po_pending = 0
        po_approved = 1
        po_rec_partial = 3
        po_rec_complete = 4
        po_status_whitelist = [po_pending, po_approved, po_rec_partial, po_rec_complete]
        li_pending = 0
        li_rec_complete = 1
        li_approved = 8
        li_rec_partial = 9
        li_status_whitelist = [li_pending, li_rec_complete, li_approved, li_rec_partial]
        status = nil
        unless (order = get_orders(bib_id)).empty?
          po_status, li_status = order.first[:po_status], order.first[:li_status]
          if po_status_whitelist.include?(po_status) or li_status_whitelist.include?(li_status)
            status = if li_status == li_rec_complete
              'Order Received'
            elsif li_status == li_pending
              'Pending Order'
            else
              'On-Order'
            end
            status << " #{order.first[:date].strftime('%m-%d-%Y')}" unless order.first[:date].nil?
          end
        end
        status
      end

      private

      def group_items(data_arr)
        hsh = data_arr.group_by { |holding| holding[:perm_location] }
        hsh.each do |location, holding_arr|
          holding_arr.each do |holding|
            holding.delete(:perm_location)
          end
        end
        hsh
      end

      # assume full access unless if the :always_requestable value for the location is true
      # or if the location is a reference location
      def limited_access_location?(loc_code)
        limited = false
        holding_location = Locations::HoldingLocation.find_by(code: loc_code)
        unless holding_location.nil? 
          limited = holding_location.always_requestable
          limited = true if holding_location.label.match(/Reference/)
        end
        limited
      end

      # Note that the hash is the result of calling `to_hash`, not `to_marchash`
      def fields_from_marc_hash(hsh, codes)
        codes = [codes] if codes.kind_of? String
        hsh['fields'].select { |f| codes.include?(f.keys.first) }
      end

      def subfields_from_field(field, codes)
        codes = [codes] if codes.kind_of? String
        field['subfields'].select { |s| codes.include?(s.keys.first) }
      end

      def id_from_mfhd_hash(hsh)
        hsh['fields'].select { |f| f.has_key?('001') }.first['001']
      end

      def holdings_notes_from_mfhd_hash(hsh)
        notes = []
        f866_arr = fields_from_marc_hash(hsh, '866')
        f866_arr.each do |f|
          text_holdings = subfields_from_field(f['866'], 'a')
          public_note = subfields_from_field(f['866'], 'z')
          notes << text_holdings.first['a'] unless text_holdings.empty?
          notes << public_note.first['z'] unless public_note.empty?
        end
        notes
      end

      def callno_from_852(hsh_852)
        subfields = hsh_852.fetch('subfields', {})
        vals = subfields_from_field(hsh_852, ['h','i'])
        parts = []
        subfields_from_field(hsh_852, ['h','i']).each do |sf|
          parts << sf.values()
        end
        parts.flatten.join (' ')
      end

      def location_from_852(hsh_852)
        subfields = hsh_852.fetch('subfields', {})
        subfields_from_field(hsh_852, 'b').first['b']
      end

      # @param bib_id [Fixnum] A bib record id
      # @return [Array<Hash>] An Array of Hashes with one key: :on_order.
      def get_orders(bib_id, conn=nil)
        query = VoyagerHelpers::Queries.orders(bib_id)
        if conn.nil?
          connection do |c|
            exec_get_orders(query, c)
          end
        else
          exec_get_orders(query, conn)
        end
      end

      # return status codes for all orders for debugging and for
      # determining availability message
      def exec_get_orders(query, conn)
        statuses = []
        conn.exec(query) do |bib_id,po_status,order_status,date|
          date = date.to_datetime unless date.nil?
          statuses << { date: date,
                        li_status: order_status,
                        po_status: po_status }
        end
        statuses
      end

      def mfhd_is_suppressed?(mfhd_id, conn=nil)
        query = VoyagerHelpers::Queries.mfhd_suppressed(mfhd_id)
        if conn.nil?
          connection do |c|
            exec_mfhd_is_suppressed?(query, c)
          end
        else
          exec_mfhd_is_suppressed?(query, conn)
        end
      end

      def exec_mfhd_is_suppressed?(query, conn)
        suppressed = false
        if conn.nil?
          connection do |c|
            suppressed = c.select_one(query) == ['Y']
          end
        else
          suppressed = conn.select_one(query) == ['Y']
        end
        suppressed
      end


      def get_info_for_item(item_id, conn=nil, full=true)
        query = full == true ? VoyagerHelpers::Queries.full_item_info(item_id) : VoyagerHelpers::Queries.brief_item_info(item_id)
        if conn.nil?
          connection do |c|
            exec_get_info_for_item(query, c, full)
          end
        else
          exec_get_info_for_item(query, conn, full)
        end
      end

      def exec_get_info_for_item(query, conn, full)
        info = {}
        conn.exec(query) do |a|
          info[:id] = a.shift
          info[:status] = a.shift
          info[:on_reserve] = a.shift
          info[:temp_location] = a.shift
          if full == true
            info[:perm_location] = a.shift
            info[:enum] = a.shift
            info[:chron] = a.shift
            info[:copy_number] = a.shift
            info[:item_sequence_number] = a.shift
            date = a.shift
            info[:status_date] = date.to_datetime unless date.nil?
            info[:barcode] = a.shift
          end
        end
        info
      end

      def exec_get_info_for_patron(query, conn)
        info = {}
        conn.exec(query) do |a|
          info[:netid] = a.shift
          info[:first_name] = a.shift
          info[:last_name] = a.shift
          info[:barcode] = a.shift
          info[:barcode_status] = a.shift
          info[:barcode_status_date] = a.shift
          info[:university_id] = a.shift
          patron_group = a.shift
          info[:patron_group] = patron_group == 3 ? 'staff' : patron_group
          info[:purge_date] = a.shift
          info[:expire_date] = a.shift
          info[:patron_id] = a.shift
        end
        info
      end

      def accumulate_items_for_holding(mfhd_id, conn)
        items = []
        item_ids = get_item_ids_for_holding(mfhd_id, conn)
        item_ids.each do |item_id|
          items << get_info_for_item(item_id, conn)
        end
        items
      end

      def get_item_ids_for_holding(mfhd_id, conn)
        query = VoyagerHelpers::Queries.mfhd_item_ids(mfhd_id)
        if conn.nil?
          connection do |c|
            exec_get_item_ids_for_holding(query, c)
          end
        else
          exec_get_item_ids_for_holding(query, conn)
        end
      end

      def exec_get_item_ids_for_holding(query, conn)
        item_ids = []
        conn.exec(query) { |item_id| item_ids << item_id }
        item_ids.flatten
      end

      def bib_is_suppressed?(bib_id, conn=nil)
        suppressed = false
        query = VoyagerHelpers::Queries.bib_suppressed(bib_id)
        if conn.nil?
          connection do |c|
            suppressed = c.select_one(query) == ['Y']
          end
        else
          suppressed = conn.select_one(query) == ['Y']
        end
        suppressed
      end

      def get_bib_without_holdings(bib_id, conn=nil)
        segments = get_bib_segments(bib_id, conn)
        MARC::Reader.decode(segments.join(''), :external_encoding => "UTF-8", :invalid => :replace, :replace => '') unless segments.empty?
      end

      def get_bib_with_holdings(bib_id, conn=nil, opts={})
        bib = get_bib_without_holdings(bib_id, conn)
        unless bib.nil?
          holdings = get_holding_records(bib_id, conn)
          if opts.fetch(:holdings_in_bib, true)
            merge_holdings_into_bib(bib, holdings, conn)
          else
            [bib,holdings].flatten!
          end
        end
      end

      # Removes bib 852s and 86Xs, adds 852s, 856s, and 86Xs from holdings, adds 959 catalog date
      def merge_holdings_into_bib(bib, holdings, conn=nil)
        record_hash = bib.to_hash
        record_hash['fields'].delete_if { |f| ['852', '866', '867', '868'].any? { |key| f.has_key?(key) } }
        unless holdings.empty?
          holdings.each do |holding|
            holding.to_hash['fields'].select { |h| ['852', '856', '866', '867', '868'].any? { |key| h.has_key?(key) } }.each do |h|
              key, _value = h.first # marc field hashes have only one key, which is the tag number
              h[key]['subfields'].unshift({"0"=>holding['001'].value})
              record_hash['fields'] << h
            end
          end
          catalog_date = get_catalog_date(bib['001'].value, holdings, conn)
          unless catalog_date.nil?
            record_hash['fields'] << {"959"=>{"ind1"=>" ", "ind2"=>" ", "subfields"=>[{"a"=>catalog_date.to_s}]}}
          end
        end
        MARC::Record.new_from_hash(record_hash)
      end

      def get_catalog_date(bib_id, holdings, conn=nil)
        if electronic_resource?(holdings, conn)
          get_bib_create_date(bib_id, conn)
        else
          get_earliest_item_date(holdings, conn) # returns nil if no items
        end
      end

      def electronic_resource?(holdings, conn=nil)
        holdings.each do |mfhd|
          mfhd_hash = mfhd.to_hash
          field_852 = fields_from_marc_hash(mfhd_hash, '852').first['852']
          online = location_from_852(field_852).start_with?('elf')
          return true if online
        end
        false
      end

      def get_bib_create_date(bib_id, conn=nil)
        query = VoyagerHelpers::Queries.bib_create_date(bib_id)
        if conn.nil?
          connection do |c|
            c.exec(query) { |date| return date.first }
          end
        else
          conn.exec(query) { |date| return date.first }
        end
      end

      def get_item_create_date(item_id, conn=nil)
        query = VoyagerHelpers::Queries.item_create_date(item_id)
        if conn.nil?
          connection do |c|
            c.exec(query) { |date| return date.first }
          end
        else
          conn.exec(query) { |date| return date.first }
        end
      end

      def get_earliest_item_date(holdings, conn=nil)
        item_ids = []
        holdings.each do |mfhd|
          mfhd_id = id_from_mfhd_hash(mfhd.to_hash)
          item_ids << get_item_ids_for_holding(mfhd_id, conn)
        end
        dates = []
        item_ids.flatten.min_by {|item_id| dates << get_item_create_date(item_id, conn)}
        dates.min
      end

      def get_bib_segments(bib_id, conn=nil)
        query = VoyagerHelpers::Queries.bib(bib_id)
        segments(query, conn)
      end

      def get_mfhd_segments(mfhd_id, conn=nil)
        query = VoyagerHelpers::Queries.mfhd(mfhd_id)
        segments(query, conn)
      end

      def segments(query, conn=nil)
        segments = []
        if conn.nil?
          connection do |c|
            c.exec(query) { |s| segments << s }
          end
        else
          conn.exec(query) { |s| segments << s }
        end
        segments
      end

      def get_bib_mfhd_ids(bib_id, conn=nil)
        query = VoyagerHelpers::Queries.mfhd_ids(bib_id)
        if conn.nil?
          connection do |c|
            exec_get_bib_mfhd_ids(query, c)
          end
        else
          exec_get_bib_mfhd_ids(query, conn)
        end
      end

      def exec_get_bib_mfhd_ids(query, conn)
        ids = []
        if conn.nil?
          connection do |c|
            c.exec(query) { |id| ids << id.first }
          end
        else
          conn.exec(query) { |id| ids << id.first }
        end
        ids
      end

      def determine_id_type(patron_id)
        if /^\d{14}$/.match(patron_id)
          'patron_barcode.patron_barcode'
        elsif /^\d{9}$/.match(patron_id)
          'patron.institution_id'
        else
          'patron.title'
        end
      end

    end # class << self
  end # class Liberator
end # module VoyagerHelpers
