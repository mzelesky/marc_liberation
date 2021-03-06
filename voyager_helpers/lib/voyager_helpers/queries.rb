module VoyagerHelpers
  module Queries
    class << self

      def bib_suppressed(bib_id)
        %Q(
        SELECT suppress_in_opac FROM bib_master
        WHERE bib_id=#{bib_id}
        )
      end

      def all_locations
        %Q(
        SELECT location_id, location_code, location_display_name,
        suppress_in_opac
        FROM location
        ORDER BY location_id
        )
      end

      def full_item_info(item_id)
        %Q(
        SELECT 
          item.item_id,
          item_status_type.item_status_desc,
          item.on_reserve,
          temp_loc.location_code,
          perm_loc.location_code,
          mfhd_item.item_enum,
          mfhd_item.chron,
          item.copy_number,
          item.item_sequence_number,
          item_status.item_status_date,
          item_barcode.item_barcode
        FROM item
          INNER JOIN location perm_loc 
            ON perm_loc.location_id = item.perm_location
          LEFT JOIN location temp_loc 
            ON temp_loc.location_id = item.temp_location
          INNER JOIN item_status
            ON item_status.item_id = item.item_id
          INNER JOIN item_status_type
            ON item_status_type.item_status_type = item_status.item_status
          INNER JOIN mfhd_item
            ON mfhd_item.item_id = item.item_id
          LEFT JOIN item_barcode
            ON item_barcode.item_id = item.item_id
        WHERE item.item_id=#{item_id} AND
          item_status.item_status NOT IN ('5', '6', '16', '19', '20', '21', '23', '24')
        )
      end

      def brief_item_info(item_id)
        %Q(
        SELECT
          item.item_id,
          item_status_type.item_status_desc,
          item.on_reserve,
          temp_loc.location_code
        FROM item
          LEFT JOIN location temp_loc
            ON temp_loc.location_id = item.temp_location
          INNER JOIN item_status
            ON item_status.item_id = item.item_id
          INNER JOIN item_status_type
            ON item_status_type.item_status_type = item_status.item_status
        WHERE item.item_id=#{item_id} AND
          item_status.item_status NOT IN ('5', '6', '16', '19', '20', '21', '23', '24')
        )
      end

      def item_create_date(item_id)
        %Q(
        SELECT
          create_date
        FROM item
        WHERE item_id=#{item_id}
        )
      end

      def orders(bib_id)
        %Q(
        SELECT LINE_ITEM.BIB_ID,
          PURCHASE_ORDER.PO_STATUS,
          LINE_ITEM_COPY_STATUS.LINE_ITEM_STATUS,
          LINE_ITEM_COPY_STATUS.STATUS_DATE
        FROM ((PURCHASE_ORDER
        INNER JOIN LINE_ITEM ON PURCHASE_ORDER.PO_ID = LINE_ITEM.PO_ID)
        INNER JOIN LINE_ITEM_COPY_STATUS ON LINE_ITEM.LINE_ITEM_ID = LINE_ITEM_COPY_STATUS.LINE_ITEM_ID)
        WHERE (LINE_ITEM.BIB_ID = #{bib_id})
        )
      end

      def statuses
        %Q(
        SELECT item_status_type, item_status_desc
        FROM item_status_type
        )
      end

      def bib(bib_id)
        %Q(
        SELECT record_segment 
        FROM bib_data
        WHERE bib_id=#{bib_id}
        ORDER BY seqnum
        )
      end

      def bib_id_for_holding_id(mfhd_id)
        %Q(
        SELECT 
          bib_master.bib_id,
          bib_master.create_date,
          bib_master.update_date
        FROM bib_master
          INNER JOIN bib_mfhd
            ON bib_mfhd.mfhd_id=#{mfhd_id}
        WHERE bib_master.bib_id = bib_mfhd.bib_id
        )
      end

      def all_unsupressed_bib_ids
        %Q(
        SELECT 
          bib_id,
          create_date,
          update_date
        FROM bib_master
        WHERE bib_master.suppress_in_opac='N'
        )
      end

      def bib_create_date(bib_id)
        %Q(
        SELECT
          create_date
        FROM bib_master
        WHERE bib_master.bib_id=#{bib_id}
        )
      end

      def all_unsupressed_mfhd_ids
        %Q(
        SELECT 
          mfhd_master.mfhd_id,
          mfhd_master.create_date,
          mfhd_master.update_date
        FROM mfhd_master 
          INNER JOIN location 
            ON mfhd_master.location_id = location.location_id
        WHERE mfhd_master.suppress_in_opac='N'
          AND location.suppress_in_opac='N'
        )
      end

      def mfhd(mfhd_id)
        %Q(
        SELECT record_segment FROM mfhd_data
        WHERE mfhd_id=#{mfhd_id}
        ORDER BY seqnum
        )
      end

      def mfhd_suppressed(mfhd_id)
        %Q(
          SELECT suppress_in_opac 
          FROM mfhd_master
          WHERE mfhd_id=#{mfhd_id}
        ) 
      end

      def mfhd_ids(bib_id)
        %Q(
        SELECT mfhd_id 
        FROM bib_mfhd
        WHERE bib_id=#{bib_id}
        )
      end

      def mfhd_item_ids(mfhd_id)
        %Q(
        SELECT item_id FROM mfhd_item
        WHERE mfhd_id=#{mfhd_id}
        )
      end

      def patron_info(id, id_field)
        %Q(
          SELECT
            patron.title,
            patron.first_name,
            patron.last_name,
            patron_barcode.patron_barcode,
            patron_barcode.barcode_status,
            patron_barcode.barcode_status_date,
            patron.institution_id,
            patron_barcode.patron_group_id,
            patron.purge_date,
            patron.expire_date,
            patron.patron_id
          FROM patron, patron_barcode
          WHERE
            #{id_field}='#{id}'
            AND patron.patron_id=patron_barcode.patron_id
            AND patron_barcode.barcode_status=1
          )
      end

      def active_courses
        %Q(
          SELECT
            reserve_list.reserve_list_id,
            department.department_name,
            course.course_name,
            course.course_number,
            reserve_list_courses.section_id,
            instructor.first_name,
            instructor.last_name
          FROM ((((reserve_list_courses join
                  department on reserve_list_courses.department_id = department.department_id) join
                  instructor on reserve_list_courses.instructor_id = instructor.instructor_id) join
                  course on reserve_list_courses.course_id = course.course_id) join
                  reserve_list on reserve_list.reserve_list_id = reserve_list_courses.reserve_list_id)
                  join reserve_list_items on reserve_list.reserve_list_id = reserve_list_items.reserve_list_id
          WHERE reserve_list.expire_date >= sysdate
          GROUP BY
            reserve_list.reserve_list_id,
            department.department_name,
            course.course_name,
            course.course_number,
            reserve_list_courses.section_id,
            instructor.first_name,
            instructor.last_name
            )
      end

      def course_bibs(reserve_list_id)
        %Q(
          SELECT
            reserve_list.reserve_list_id,
            bib_item.bib_id
          FROM ((reserve_list join
               reserve_list_items on reserve_list.reserve_list_id = reserve_list_items.reserve_list_id) join
               bib_item on reserve_list_items.item_id = bib_item.item_id)
          WHERE reserve_list.reserve_list_id = #{reserve_list_id}
          GROUP BY reserve_list.reserve_list_id,
                    bib_item.bib_id
        )
      end

      def current_periodicals(mfhd_id)
        %Q(
        SELECT
          SERIAL_ISSUES.ENUMCHRON
        FROM (LINE_ITEM INNER JOIN LINE_ITEM_COPY_STATUS ON LINE_ITEM.LINE_ITEM_ID = LINE_ITEM_COPY_STATUS.LINE_ITEM_ID) INNER JOIN
             (((SUBSCRIPTION INNER JOIN COMPONENT ON SUBSCRIPTION.SUBSCRIPTION_ID = COMPONENT.SUBSCRIPTION_ID) INNER JOIN
             ISSUES_RECEIVED ON COMPONENT.COMPONENT_ID = ISSUES_RECEIVED.COMPONENT_ID) INNER JOIN
             SERIAL_ISSUES ON (ISSUES_RECEIVED.COMPONENT_ID = SERIAL_ISSUES.COMPONENT_ID) AND
             (ISSUES_RECEIVED.ISSUE_ID = SERIAL_ISSUES.ISSUE_ID)) ON LINE_ITEM_COPY_STATUS.LINE_ITEM_ID = SUBSCRIPTION.LINE_ITEM_ID
        WHERE (((LINE_ITEM_COPY_STATUS.MFHD_ID = #{mfhd_id}) AND (SERIAL_ISSUES.RECEIVED)='1') AND ((ISSUES_RECEIVED.OPAC_SUPPRESSED)='1'))
        GROUP BY LINE_ITEM_COPY_STATUS.MFHD_ID, SERIAL_ISSUES.ENUMCHRON
        )
      end
    end # class << self
  end # module Queries
end # module VoyagerHelpers








