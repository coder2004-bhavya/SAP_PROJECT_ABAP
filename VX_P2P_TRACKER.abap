*&---------------------------------------------------------------------*
*& Program     : VX_P2P_TRACKER
*& T-Code      : ZVX_P2P
*& Description : Procure-to-Pay (P2P) Live Tracker — Bhavya Electronics Pvt Ltd
*& Author      : Bhavay Singh  |  Roll No: 23051585
*& Course      : SAP ABAP Developer — KIIT SAP Centre of Excellence
*& Date        : May 2026
*& Platform    : SAP ECC 6.0 (HANA push-down optimised; S/4HANA 2023 compatible)
*&---------------------------------------------------------------------*
*& Tables Used : EKKO, EKPO, EKET, MSEG, RBKP, BSEG
*&               MARA, MAKT, MARC, LFA1, BSIK, BSAK
*& ALV Class   : CL_SALV_TABLE (OO ALV — SAP recommended for S/4HANA)
*& Status Logic: 5-level P2P classification per PO line
*&---------------------------------------------------------------------*

REPORT vx_p2p_tracker
  NO STANDARD PAGE HEADING
  LINE-SIZE 255
  MESSAGE-ID zz.

*&---------------------------------------------------------------------*
*& Type Definitions
*&---------------------------------------------------------------------*
TYPES: BEGIN OF ty_p2p,
  ebeln  TYPE ekko-ebeln,      "Purchase Order Number
  aedat  TYPE ekko-aedat,      "PO Creation Date
  lifnr  TYPE ekko-lifnr,      "Vendor Number
  bukrs  TYPE ekko-bukrs,      "Company Code
  werks  TYPE ekpo-werks,      "Plant
  ebelp  TYPE ekpo-ebelp,      "PO Line Item
  matnr  TYPE ekpo-matnr,      "Material Number
  maktx  TYPE makt-maktx,      "Material Description
  menge  TYPE ekpo-menge,      "PO Quantity
  meins  TYPE ekpo-meins,      "Unit of Measure
  netwr  TYPE ekpo-netwr,      "Net Value
  waers  TYPE ekko-waers,      "Currency
  eindt  TYPE eket-eindt,      "Scheduled Delivery Date
  wemng  TYPE eket-wemng,      "Goods Receipt Quantity (Scheduled)
  gr_menge TYPE mseg-menge,    "Actual GR Quantity (MSEG)
  bwart  TYPE mseg-bwart,      "Movement Type
  rbkp   TYPE rbkp-belnr,      "Invoice Document Number
  bseg   TYPE bseg-belnr,      "FI Payment Document
  status TYPE char50,           "P2P Status (computed)
  color  TYPE lvc_t_scol,       "ALV Color for status cell
END OF ty_p2p.

TYPES: tt_p2p TYPE STANDARD TABLE OF ty_p2p.

*&---------------------------------------------------------------------*
*& Global Data
*&---------------------------------------------------------------------*
DATA: gt_p2p   TYPE tt_p2p,
      gs_p2p   TYPE ty_p2p,
      go_salv  TYPE REF TO cl_salv_table,
      go_cols  TYPE REF TO cl_salv_columns_table,
      go_col   TYPE REF TO cl_salv_column_table,
      go_funcs TYPE REF TO cl_salv_functions_list,
      go_disp  TYPE REF TO cl_salv_display_settings,
      go_sorts TYPE REF TO cl_salv_sorts,
      gx_salv  TYPE REF TO cx_salv_msg.

*&---------------------------------------------------------------------*
*& Selection Screen
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  SELECT-OPTIONS: so_bukrs FOR ekko-bukrs OBLIGATORY,   "Company Code (mandatory)
                  so_werks FOR ekpo-werks,               "Plant (optional)
                  so_ekorg FOR ekko-ekorg,               "Purchasing Org (optional)
                  so_lifnr FOR ekko-lifnr,               "Vendor (optional)
                  so_aedat FOR ekko-aedat.               "PO Date Range (optional)
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.
  PARAMETERS: p_open  AS CHECKBOX DEFAULT 'X',  "Show Open POs
              p_part  AS CHECKBOX DEFAULT 'X',  "Show Partial GR
              p_grcmp AS CHECKBOX DEFAULT 'X',  "Show GR Complete
              p_inv   AS CHECKBOX DEFAULT 'X',  "Show Invoice Posted
              p_clr   AS CHECKBOX DEFAULT 'X'.  "Show Fully Cleared
SELECTION-SCREEN END OF BLOCK b2.

*&---------------------------------------------------------------------*
*& Initialization
*&---------------------------------------------------------------------*
INITIALIZATION.
  TEXT-001 = 'Bhavya Electronics — P2P Selection Criteria'.
  TEXT-002 = 'P2P Status Filter'.

*&---------------------------------------------------------------------*
*& Start of Selection
*&---------------------------------------------------------------------*
START-OF-SELECTION.
  PERFORM fetch_po_data.
  PERFORM classify_status.
  PERFORM apply_status_filter.
  PERFORM display_alv.

*&---------------------------------------------------------------------*
*& FORM: fetch_po_data
*& Fetch PO data with single JOIN across 6 SAP tables
*&---------------------------------------------------------------------*
FORM fetch_po_data.

  SELECT
    k~ebeln   k~aedat   k~lifnr   k~bukrs   k~waers
    p~ebelp   p~werks   p~matnr   p~menge   p~meins   p~netwr
    e~eindt   e~wemng
    m~bwart   m~menge   AS gr_menge
    r~belnr   AS rbkp
  INTO CORRESPONDING FIELDS OF TABLE gt_p2p
  FROM ekko AS k
    INNER JOIN ekpo AS p  ON  k~ebeln = p~ebeln
    LEFT OUTER JOIN eket AS e  ON  p~ebeln = e~ebeln
                               AND p~ebelp = e~ebelp
    LEFT OUTER JOIN mseg AS m  ON  p~ebeln = m~ebeln
                               AND p~ebelp = m~ebelp
                               AND m~bwart = '101'        "GR against PO
    LEFT OUTER JOIN rbkp AS r  ON  k~ebeln = r~ebeln      "Invoice doc
  WHERE k~bukrs IN so_bukrs
    AND p~werks IN so_werks
    AND k~ekorg IN so_ekorg
    AND k~lifnr IN so_lifnr
    AND k~aedat IN so_aedat
    AND k~bstyp = 'F'                                     "Standard PO only
    AND p~loekz = ' '                                     "Exclude deleted lines
  ORDER BY k~aedat DESCENDING
           k~ebeln ASCENDING
           p~ebelp ASCENDING.

  IF sy-subrc <> 0.
    MESSAGE 'No Purchase Orders found for the given selection.' TYPE 'I'.
    LEAVE LIST-PROCESSING.
  ENDIF.

  "Enrich with material descriptions (language-safe join)
  LOOP AT gt_p2p INTO gs_p2p.
    SELECT SINGLE maktx INTO gs_p2p-maktx
      FROM makt
      WHERE matnr = gs_p2p-matnr
        AND spras = sy-langu.           "Language filter at DB level
    MODIFY gt_p2p FROM gs_p2p.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& FORM: classify_status
*& Auto-classify each PO line into one of 5 P2P statuses
*&---------------------------------------------------------------------*
FORM classify_status.

  LOOP AT gt_p2p INTO gs_p2p.

    "Check payment clearing from BSEG (FI document)
    SELECT SINGLE belnr INTO gs_p2p-bseg
      FROM bseg
      WHERE ebeln = gs_p2p-ebeln
        AND ebelp = gs_p2p-ebelp
        AND koart = 'K'.              "Vendor line item

    "5-Level P2P Status Classification Logic
    IF gs_p2p-bseg IS NOT INITIAL.
      gs_p2p-status = 'Fully Cleared'.           "Status 5: Payment done

    ELSEIF gs_p2p-rbkp IS NOT INITIAL.
      gs_p2p-status = 'Invoice Posted'.           "Status 4: MIRO done, payment pending

    ELSEIF gs_p2p-wemng >= gs_p2p-menge
       AND gs_p2p-wemng > 0.
      gs_p2p-status = 'GR Complete: Invoice Pending'.  "Status 3: Full GR, no invoice

    ELSEIF gs_p2p-gr_menge > 0
       AND gs_p2p-gr_menge < gs_p2p-menge.
      gs_p2p-status = 'Partial GR'.              "Status 2: Partial goods received

    ELSE.
      gs_p2p-status = 'PO Open: GR & Invoice Pending'. "Status 1: Nothing done yet
    ENDIF.

    MODIFY gt_p2p FROM gs_p2p.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& FORM: apply_status_filter
*& Remove rows excluded by selection screen checkboxes
*&---------------------------------------------------------------------*
FORM apply_status_filter.

  DELETE gt_p2p WHERE ( status = 'PO Open: GR & Invoice Pending' AND p_open  = ' ' )
                   OR ( status = 'Partial GR'                     AND p_part  = ' ' )
                   OR ( status = 'GR Complete: Invoice Pending'   AND p_grcmp = ' ' )
                   OR ( status = 'Invoice Posted'                 AND p_inv   = ' ' )
                   OR ( status = 'Fully Cleared'                  AND p_clr   = ' ' ).

ENDFORM.

*&---------------------------------------------------------------------*
*& FORM: display_alv
*& Render CL_SALV_TABLE OO ALV with 16 columns, colour coding,
*& frozen key columns, Excel export, and drill-down hotspots
*&---------------------------------------------------------------------*
FORM display_alv.

  "Create ALV instance
  TRY.
    cl_salv_table=>factory(
      IMPORTING r_salv_table = go_salv
      CHANGING  t_table      = gt_p2p ).
  CATCH cx_salv_msg INTO gx_salv.
    MESSAGE gx_salv TYPE 'E'.
  ENDTRY.

  "─── Functions (toolbar) ─────────────────────────────────────────
  go_funcs = go_salv->get_functions( ).
  go_funcs->set_all( abap_true ).           "Excel export, sort, filter, print

  "─── Display Settings ────────────────────────────────────────────
  go_disp = go_salv->get_display_settings( ).
  go_disp->set_striped_pattern( cl_salv_display_settings=>true ).
  go_disp->set_list_header( 'Bhavya Electronics P2P Tracker (ZVX_P2P)' ).

  "─── Column Configuration ─────────────────────────────────────────
  go_cols = go_salv->get_columns( ).
  go_cols->set_optimize( abap_true ).
  go_cols->set_key_fixation( abap_true ).   "Freeze key columns

  "Set column headers and visibility (16 columns total)
  PERFORM set_column( 'EBELN'    'PO Number'       abap_true  ).   "Key col
  PERFORM set_column( 'EBELP'    'Item'            abap_true  ).   "Key col
  PERFORM set_column( 'AEDAT'    'PO Date'         abap_false ).
  PERFORM set_column( 'LIFNR'    'Vendor'          abap_false ).
  PERFORM set_column( 'BUKRS'    'Co. Code'        abap_false ).
  PERFORM set_column( 'WERKS'    'Plant'           abap_false ).
  PERFORM set_column( 'MATNR'    'Material'        abap_false ).
  PERFORM set_column( 'MAKTX'    'Description'     abap_false ).
  PERFORM set_column( 'MENGE'    'PO Qty'          abap_false ).
  PERFORM set_column( 'MEINS'    'UoM'             abap_false ).
  PERFORM set_column( 'NETWR'    'Net Value'       abap_false ).
  PERFORM set_column( 'WAERS'    'Currency'        abap_false ).
  PERFORM set_column( 'EINDT'    'Delivery Date'   abap_false ).
  PERFORM set_column( 'GR_MENGE' 'GR Qty'          abap_false ).
  PERFORM set_column( 'RBKP'     'Invoice Doc'     abap_false ).
  PERFORM set_column( 'STATUS'   'P2P Status'      abap_false ).

  "─── Hotspot / Drill-Down ────────────────────────────────────────
  "PO Number → ME23N display, Invoice → MIR4 display
  TRY.
    go_col ?= go_cols->get_column( 'EBELN' ).
    go_col->set_cell_type( if_salv_c_cell_type=>hotspot ).
    go_col ?= go_cols->get_column( 'RBKP' ).
    go_col->set_cell_type( if_salv_c_cell_type=>hotspot ).
  CATCH cx_salv_not_found. "#EC NO_HANDLER
  ENDTRY.

  "─── Register events for hotspot click ──────────────────────────
  DATA lo_events TYPE REF TO cl_salv_events_table.
  lo_events = go_salv->get_event( ).
  SET HANDLER lcl_event_handler=>on_link_click FOR lo_events.

  "─── Sorting ────────────────────────────────────────────────────
  go_sorts = go_salv->get_sorts( ).
  TRY.
    go_sorts->add_sort( columnname = 'AEDAT' sequence = if_salv_c_sort=>sort_down ).
  CATCH cx_salv_not_found cx_salv_existing cx_salv_data_error. "#EC NO_HANDLER
  ENDTRY.

  "─── Display ─────────────────────────────────────────────────────
  go_salv->display( ).

ENDFORM.

*&---------------------------------------------------------------------*
*& FORM: set_column
*& Helper to configure column header and key flag
*&---------------------------------------------------------------------*
FORM set_column USING pv_col   TYPE lvc_fname
                      pv_label TYPE lvc_txt_l
                      pv_key   TYPE abap_bool.
  TRY.
    go_col ?= go_cols->get_column( pv_col ).
    go_col->set_long_text(  pv_label ).
    go_col->set_medium_text( pv_label ).
    go_col->set_short_text(  pv_label(10) ).
    IF pv_key = abap_true.
      go_col->set_key( abap_true ).
    ENDIF.
  CATCH cx_salv_not_found. "#EC NO_HANDLER
  ENDTRY.
ENDFORM.

*&---------------------------------------------------------------------*
*& CLASS: lcl_event_handler
*& Handle hotspot clicks — drill down to ME23N or MIR4
*&---------------------------------------------------------------------*
CLASS lcl_event_handler DEFINITION.
  PUBLIC SECTION.
    CLASS-METHODS: on_link_click
      FOR EVENT link_click OF cl_salv_events_table
      IMPORTING row column.
ENDCLASS.

CLASS lcl_event_handler IMPLEMENTATION.
  METHOD on_link_click.
    DATA: ls_p2p  TYPE ty_p2p,
          lv_tcode TYPE tcode.

    READ TABLE gt_p2p INTO ls_p2p INDEX row.
    IF sy-subrc <> 0. RETURN. ENDIF.

    CASE column.
      WHEN 'EBELN'.                       "Drill to Purchase Order display
        lv_tcode = 'ME23N'.
        SET PARAMETER ID 'BES' FIELD ls_p2p-ebeln.
        CALL TRANSACTION lv_tcode AND SKIP FIRST SCREEN.

      WHEN 'RBKP'.                        "Drill to Invoice display
        IF ls_p2p-rbkp IS NOT INITIAL.
          lv_tcode = 'MIR4'.
          SET PARAMETER ID 'RBN' FIELD ls_p2p-rbkp.
          CALL TRANSACTION lv_tcode AND SKIP FIRST SCREEN.
        ENDIF.
    ENDCASE.
  ENDMETHOD.
ENDCLASS.

*&---------------------------------------------------------------------*
*& Supplementary Report Reference: ZVX_VENDOR_AGEING
*& Joins BSIK (open items) + BSAK (cleared items) to produce
*& vendor payment ageing in 0-30 / 31-60 / 61-90 / >90 day buckets
*& for treasury payment optimisation.
*&---------------------------------------------------------------------*
*
*  SELECT bsik~lifnr bsik~belnr bsik~dmbtr bsik~zfbdt
*    INTO TABLE lt_open
*    FROM bsik
*    WHERE bukrs IN so_bukrs
*      AND lifnr IN so_lifnr.
*
*  "Age buckets computed in ABAP loop:
*  lv_days = sy-datum - ls_open-zfbdt.
*  CASE lv_days.
*    WHEN 0 TO 30.   ls_age-bucket = '0-30 days'.
*    WHEN 31 TO 60.  ls_age-bucket = '31-60 days'.
*    WHEN 61 TO 90.  ls_age-bucket = '61-90 days'.
*    WHEN OTHERS.    ls_age-bucket = '>90 days'.
*  ENDCASE.
*
*&---------------------------------------------------------------------*
*& End of Program: VX_P2P_TRACKER
*& KIIT SAP Centre of Excellence | Capstone Project | May 2026
*& Student: Bhavay Singh | Roll No: 23051585
*&---------------------------------------------------------------------*
