;; -*-scheme-*-
;; owner-report.scm -- Print out a detailed owner report, which is a
;;                     summary of invoices and payments for a particular
;;                     company (the owner) applied to an account.
;;
;; Created by:  Derek Atkins <warlord@MIT.EDU>
;; Copyright (c) 2002, 2003 Derek Atkins <warlord@MIT.EDU>
;; Modified by AMM to show tax figures of invoice.
;; Modified by Christopher Lam to combine job/owner-report
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2 of
;; the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, contact:
;;
;; Free Software Foundation           Voice:  +1-617-542-5942
;; 51 Franklin Street, Fifth Floor    Fax:    +1-617-542-2652
;; Boston, MA  02110-1301,  USA       gnu@gnu.org


(define-module (gnucash reports standard new-owner-report))

(use-modules (srfi srfi-1))
(use-modules (srfi srfi-2))
(use-modules (srfi srfi-8))
(use-modules (srfi srfi-9))
(use-modules (srfi srfi-11))             ;for let-values
(use-modules (ice-9 match))
(use-modules (gnucash engine))
(use-modules (gnucash utilities))        ; for gnc:debug
(use-modules (gnucash core-utils))
(use-modules (gnucash app-utils))
(use-modules (gnucash report))

;; Option names
(define optname-from-date (N_ "From"))
(define optname-to-date (N_ "To"))
(define optname-date-driver (N_ "Due or Post Date"))

(define owner-page gnc:pagename-general)
(define date-header (N_ "Date"))
(define due-date-header (N_ "Due Date"))
(define reference-header (N_ "Reference"))
(define type-header (N_ "Type"))
(define desc-header (N_ "Description"))
(define sale-header (N_ "Sale"))
(define tax-header (N_ "Tax"))
(define credit-header (N_ "Credits"))
(define debit-header (N_ "Debits"))
(define balance-header (N_ "Balance"))
(define doclink-header (N_ "Document Links"))
(define linked-txns-header (N_ "Transaction Links"))

(define javascript "
<script>
  function getID(cell) { return cell.getAttribute('link-id'); }

  function clicky() {
      var id = getID(this);
      var ishighlighted = this.classList.contains('highlight');
      TDs.forEach (function (item, idx) {
          item.classList.remove('highlight')});
      if (ishighlighted) return;
      TDs.forEach (function (item, idx) {
          if (getID(item) == id)
              item.classList.add('highlight')})}

  var TDs = document.getElementsByTagName('td');
  TDs = Array.prototype.slice.call (TDs);
  TDs = TDs.filter (getID);
  TDs.forEach(function (item, idx) {
      item.addEventListener('click', clicky)});
</script>
")

;; Depending on the report type we want to set up some lists/cases
;; with strings to ease overview and translation
(define owner-string-alist
  (list
   (list GNC-OWNER-CUSTOMER
         (N_ "Customer")
         (G_ "No valid customer selected.")
         (G_ "This report requires a customer to be selected."))

   (list GNC-OWNER-EMPLOYEE
         (N_ "Employee")
         (G_ "No valid employee selected.")
         (G_ "This report requires a employee to be selected."))

   (list GNC-OWNER-JOB
         (N_ "Job")
         (G_ "No valid job selected.")
         (G_ "This report requires a job to be selected."))

   (list GNC-OWNER-VENDOR
         (N_ "Vendor")
         (G_ "No valid vendor selected.")
         (G_ "This report requires a vendor to be selected."))))

(define (get-info key)
  (assv-ref owner-string-alist key))

(define-record-type :link-data
  (make-link-data date ref type desc partial-amount amount rhs-class)
  link-data?
  (date link-data-date)
  (ref link-data-ref)
  (type link-data-type)
  (desc link-data-desc)
  (partial-amount link-data-partial-amount)
  (amount link-data-amount)
  (rhs-class link-data-rhs-class))

(define-record-type :link-desc-amount
  (make-link-desc-amount desc amount rhs-class)
  link-desc-amount?
  (desc link-desc-amount-desc)
  (amount link-desc-amount-amount)
  (rhs-class link-desc-amount-rhs-class))

(define-record-type :link-blank
  (make-link-blank)
  link-blank?)

;; Names in Option panel (Untranslated! Because it is used for option
;; naming and lookup only, and the display of the option name will be
;; translated somewhere else.)
(define (owner-string owner-type)
  (car (get-info owner-type)))

(define (date-col columns-used)
  (vector-ref columns-used 0))
(define (date-due-col columns-used)
  (vector-ref columns-used 1))
(define (ref-col columns-used)
  (vector-ref columns-used 2))
(define (type-col columns-used)
  (vector-ref columns-used 3))
(define (desc-col columns-used)
  (vector-ref columns-used 4))
(define (sale-col columns-used)
  (vector-ref columns-used 5))
(define (tax-col columns-used)
  (vector-ref columns-used 6))
(define (debit-col columns-used)
  (vector-ref columns-used 7))
(define (credit-col columns-used)
  (vector-ref columns-used 8))
(define (bal-col columns-used)
  (vector-ref columns-used 9))
(define (doclink-col columns-used)
  (vector-ref columns-used 10))

(define (num-cols columns-used section)
  (let* ((date? (date-col columns-used))
         (due? (date-due-col columns-used))
         (ref? (ref-col columns-used))
         (type? (type-col columns-used))
         (desc? (desc-col columns-used))
         (sale? (sale-col columns-used))
         (tax? (tax-col columns-used))
         (credit? (credit-col columns-used))
         (debit? (debit-col columns-used))
         (bal? (bal-col columns-used))
         (doclink? (doclink-col columns-used))
         (spacer? (or date? type? ref? desc? debit? credit?))
         (amt? (or credit? debit?))
         (cols-alist
          (list
           (list 'lhs-cols date? due? ref? type? desc? sale? tax? credit? debit? bal?
                 doclink?)
           (list 'ptt-span date? due? ref? type? desc? doclink?)
           (list 'mid-spac spacer?)
           (list 'rhs-cols date? ref? type? desc? amt? amt?)
           (list 'rhs-span date? ref? type? desc?)))
         (cols-list (assq-ref cols-alist section)))
    (count identity cols-list)))

(define (build-column-used options)
  (define (opt-val name)
    (gnc:option-value
     (gnc:lookup-option options "Display Columns" name)))
  (list->vector
   (map opt-val
        (list date-header due-date-header reference-header type-header
              desc-header sale-header tax-header debit-header credit-header
              balance-header doclink-header))))

(define (make-heading-list column-vector link-option)
  (let ((heading-list '()))
    (if (date-col column-vector)
        (addto! heading-list (G_ date-header)))
    (if (date-due-col column-vector)
        (addto! heading-list (G_ due-date-header)))
    (if (ref-col column-vector)
        (addto! heading-list (G_ reference-header)))
    (if (type-col column-vector)
        (addto! heading-list (G_ type-header)))
    (if (desc-col column-vector)
        (addto! heading-list (G_ desc-header)))
    (if (doclink-col column-vector)
        (addto! heading-list (C_ "Column header for 'Document Link'" "L")))
    (if (sale-col column-vector)
        (addto! heading-list (G_ sale-header)))
    (if (tax-col column-vector)
        (addto! heading-list (G_ tax-header)))
    (if (debit-col column-vector)
        (addto! heading-list (G_ debit-header)))
    (if (credit-col column-vector)
        (addto! heading-list (G_ credit-header)))
    (if (bal-col column-vector)
        (addto! heading-list (G_ balance-header)))
    (case link-option
      ((simple)
       (addto! heading-list (G_ linked-txns-header)))
      ((detailed)
       (if (< 0 (num-cols column-vector 'mid-spac)) (addto! heading-list #f))
       (if (date-col column-vector) (addto! heading-list (G_ "Date")))
       (if (ref-col column-vector) (addto! heading-list (G_ "Reference")))
       (if (type-col column-vector) (addto! heading-list (G_ "Type")))
       (if (desc-col column-vector) (addto! heading-list (G_ "Description")))
       (if (or (debit-col column-vector) (credit-col column-vector))
           (addto! heading-list (G_ "Partial Amount")))
       (if (or (debit-col column-vector) (credit-col column-vector))
           (addto! heading-list (G_ "Amount")))))
    (reverse heading-list)))

(define num-buckets 6)

(define (sign-equal? a b)
  (or (= 0 a b) (< 0 (* a b))))
(define (lot-split->posting-split split)
  (let* ((lot (xaccSplitGetLot split))
         (invoice (gncInvoiceGetInvoiceFromLot lot))
         (post-txn (gncInvoiceGetPostedTxn invoice)))
    (and (not (null? lot))
         (not (null? invoice))
         (not (null? post-txn))
         (find (lambda (split) (equal? (xaccSplitGetParent split) post-txn))
               (gnc-lot-get-split-list lot)))))
(define (txn-is-invoice? txn)
  (eqv? (xaccTransGetTxnType txn) TXN-TYPE-INVOICE))
(define (txn-is-payment? txn)
  (eqv? (xaccTransGetTxnType txn) TXN-TYPE-PAYMENT))
(define (txn-is-link? txn)
  (eqv? (xaccTransGetTxnType txn) TXN-TYPE-LINK))
(define (split-is-payment? split)
  (txn-is-payment? (xaccSplitGetParent split)))

(define (invoice->anchor inv)
  (gnc:html-markup-anchor
   (gnc:invoice-anchor-text inv)
   (gncInvoiceGetID inv)))

(define (split->reference split)
  (let* ((txn (xaccSplitGetParent split))
         (type (xaccTransGetTxnType txn)))
    (cond
     ((memv type (list TXN-TYPE-LINK TXN-TYPE-PAYMENT))
      (let ((ref (gnc-get-num-action txn split)))
        (gnc:make-html-text
         (gnc:html-markup-anchor
          (gnc:split-anchor-text split) ref))))
     ((eqv? type TXN-TYPE-INVOICE)
      (let ((inv (gncInvoiceGetInvoiceFromLot (xaccSplitGetLot split))))
        (gnc:make-html-text (invoice->anchor inv)))))))

(define (split->type-str split payable?)
  (let* ((txn (xaccSplitGetParent split))
         (amt (xaccSplitGetAmount split))
         (refund? (if payable? (< amt 0) (> amt 0)))
         (invoice (gncInvoiceGetInvoiceFromTxn txn)))
    (cond
     ((txn-is-invoice? txn) (gncInvoiceGetTypeString invoice))
     ((txn-is-payment? txn) (if refund? (G_ "Refund") (G_ "Payment")))
     ((txn-is-link? txn) (G_ "Link"))
     (else (G_ "Unknown")))))

;; input: list of html-text elements
;; output: a cell with html-text interleaved with <br> tags
(define* (list->cell lst #:optional skip-empty?)
  (let lp ((lst lst) (result '()))
    (match lst
      (() (apply gnc:make-html-text result))
      (("" . rest) (=> fail) (if skip-empty? (lp rest result) (fail)))
      ((elt . rest) (lp rest (cons* elt (gnc:html-markup-br) result))))))

(define* (splits->desc splits #:optional skip-empty?)
  (list->cell (map (compose gnc:html-string-sanitize xaccSplitGetMemo) splits)
              skip-empty?))

(define (make-aging-table splits to-date payable? date-type currency)
  (let ((table (gnc:make-html-table))
        (aging-list (gnc:owner-splits->aging-list
                     splits num-buckets to-date date-type (not payable?))))

    (gnc:html-table-set-col-headers!
     table (list (G_ "Pre-Payment")
                 (G_ "Current")
                 (G_ "0-30 days")
                 (G_ "31-60 days")
                 (G_ "61-90 days")
                 (G_ "91+ days")
                 (G_ "Total")))

    (gnc:html-table-append-row!
     table (map (lambda (entry) (gnc:make-gnc-monetary currency entry))
                (reverse (cons (apply + aging-list) aging-list))))
    table))

;; addif is a macro; a simple procedure will always evaluate the
;; arguments pred? and elt which is not desirable; a macro will ensure
;; elt is only evaluated if pred? is not #f
(define-syntax-rule (addif pred? elt)
  (if pred? (list elt) '()))

(define (make-section-heading-list column-vector owner-desc)
  (define (make-heading cols str)
    (gnc:make-html-table-cell/size/markup 1 cols "th" str))
  (let ((lhs (num-cols column-vector 'lhs-cols))
        (mid (num-cols column-vector 'mid-spac))
        (rhs (num-cols column-vector 'rhs-cols)))
    (append
     ;; Translators: ~a History refers to main details table in owner
     ;; report. ~a will be replaced with Customer, Vendor or Employee.
     (addif (< 0 lhs) (make-heading lhs (format #f (G_ "~a History") owner-desc)) )
     (addif (< 0 mid) (make-heading mid #f))
     (addif (< 0 rhs) (make-heading rhs (G_ "Linked Details"))))))
;;
;; Make a row list based on the visible columns
;;
(define (add-row table odd-row? column-vector date due-date ref type-str
                 desc doclink-invoice currency amt debit credit sale tax lhs-class
                 link-option link-rows)
  (define nrows (if link-rows (length link-rows) 1))
  (define (link-data->cols link-data)
    (cond
     ((link-data? link-data)
      (append
       (map
        (lambda (str)
          (let ((cell (gnc:make-html-table-cell str))
                (rhs-class (link-data-rhs-class link-data)))
            (when rhs-class
              (gnc:html-table-cell-set-style!
               cell "td" 'attribute (list "link-id" rhs-class)))
            cell))
        (append
         (addif (date-col column-vector) (link-data-date link-data))
         (addif (ref-col column-vector) (link-data-ref link-data))
         (addif (type-col column-vector) (link-data-type link-data))
         (addif (desc-col column-vector) (link-data-desc link-data))))
       (map
        (lambda (str)
          (let ((cell (gnc:make-html-table-cell/markup "number-cell" str))
                (rhs-class (link-data-rhs-class link-data)))
            (when rhs-class
              (gnc:html-table-cell-set-style!
               cell "number-cell" 'attribute (list "link-id" rhs-class)))
            cell))
        (append
         (addif (or (debit-col column-vector) (credit-col column-vector))
                (link-data-partial-amount link-data))
         (addif (or (debit-col column-vector) (credit-col column-vector))
                (link-data-amount link-data))))))

     ((link-desc-amount? link-data)
      (let ((cols (num-cols column-vector 'rhs-span)))
        (append
         (map
          (lambda (str)
            (let ((cell (gnc:make-html-table-cell/size 1 cols str))
                  (rhs-class (link-desc-amount-rhs-class link-data)))
              (when rhs-class
                (gnc:html-table-cell-set-style!
                 cell "td" 'attribute (list "link-id" rhs-class)))
              cell))
          (addif (< 0 cols) (link-desc-amount-desc link-data)))
         (map
          (lambda (str)
            (let ((cell (gnc:make-html-table-cell/size/markup 1 2 "number-cell" str))
                  (rhs-class (link-desc-amount-rhs-class link-data)))
              (when rhs-class
                (gnc:html-table-cell-set-style!
                 cell "number-cell" 'attribute (list "link-id" rhs-class)))
              cell))
          (addif (or (debit-col column-vector) (credit-col column-vector))
                 (link-desc-amount-amount link-data))))))

     ((link-blank? link-data)
      (make-list (num-cols column-vector 'rhs-cols) #f))

     (else link-data)))
  (define (cell amt)
    (and amt (gnc:make-gnc-monetary currency amt)))
  (define cell-nohoriz
    (let ((cell (gnc:make-html-table-cell/size nrows 1 #f)))
      (gnc:html-table-cell-set-style!
       cell "td" 'attribute '("style" "border-bottom: none; border-top: none;"))
      cell))
  (define mid-span
    (if (eq? link-option 'detailed) (num-cols column-vector 'mid-spac) 0))

  (let lp ((link-rows link-rows)
           (first-row? #t))
    (unless (null? link-rows)
      (if first-row?
          (gnc:html-table-append-row/markup!
           table (if odd-row? "normal-row" "alternate-row")
           (append
            (map
             (lambda (str)
               (let ((cell (gnc:make-html-table-cell/size nrows 1 str)))
                 (when lhs-class
                   (gnc:html-table-cell-set-style!
                    cell "td" 'attribute (list "link-id" lhs-class)))
                 cell))
             (append
              (addif (date-col column-vector) (qof-print-date date))
              (addif (date-due-col column-vector)
                     (and due-date (qof-print-date due-date)))
              (addif (ref-col column-vector)    ref)
              (addif (type-col column-vector)   type-str)
              (addif (desc-col column-vector)   desc)
              (addif (doclink-col column-vector)
                     (and doclink-invoice
                          (gnc:html-invoice-doclink-anchor
                           doclink-invoice
                           (C_ "Column header for 'Document Link'" "L"))))))
            (map
             (lambda (str)
               (let ((cell (gnc:make-html-table-cell/size/markup
                            nrows 1 "number-cell" str)))
                 (when lhs-class
                   (gnc:html-table-cell-set-style!
                    cell "number-cell" 'attribute (list "link-id" lhs-class)))
                 cell))
             (append
              (addif (sale-col column-vector)    (cell sale))
              (addif (tax-col column-vector)     (cell tax))
              (addif (debit-col column-vector)   debit)
              (addif (credit-col column-vector)  credit)))
            (addif (bal-col column-vector)
                   (gnc:make-html-table-cell/size/markup
                    nrows 1 "number-cell" (cell amt)))
            (addif (< 0 mid-span) cell-nohoriz)
            (link-data->cols (car link-rows))))
          (gnc:html-table-append-row/markup!
           table (if odd-row? "normal-row" "alternate-row")
           (link-data->cols (car link-rows))))
      (lp (cdr link-rows) #f))))

(define (add-owner-table table splits acc start-date end-date date-type
                         used-columns payable? link-option)
  (define (AP-negate num)
    (if payable? (- num) num))
  (define currency (xaccAccountGetCommodity acc))
  (define rhs-cols (assq-ref `((none . 0)
                               (simple . 1)
                               (detailed . ,(num-cols used-columns 'rhs-cols)))
                             link-option))
  (define mid-span
    (if (eq? link-option 'detailed) (num-cols used-columns 'mid-spac) 0))

  (define add-derived-amounts-disclaimer? #f)

  (define (split->anchor split negate?)
    (gnc:html-markup-anchor
     (gnc:split-anchor-text split)
     (gnc:make-gnc-monetary
      (xaccAccountGetCommodity (xaccSplitGetAccount split))
      ((if negate? - +)
       (AP-negate (xaccSplitGetAmount split))))))

  (define (print-totals total debit credit tax sale invalid-splits)
    (define (total-cell cell)
      (gnc:make-html-table-cell/markup "total-number-cell" cell))
    (define (make-cell amt)
      (total-cell (gnc:make-gnc-monetary currency amt)))
    (define period-span (num-cols used-columns 'ptt-span))
    (define grand-span (num-cols used-columns 'lhs-cols))
    ;; print period totals
    (if (or (sale-col used-columns) (tax-col used-columns)
            (credit-col used-columns) (debit-col used-columns))
        (gnc:html-table-append-row/markup!
         table "grand-total"
         (append
          (addif (< 0 period-span) (gnc:make-html-table-cell/markup
                                    "total-label-cell" (G_ "Period Totals")))
          (addif (< 1 period-span) (gnc:make-html-table-cell/size
                                    1 (1- period-span) #f))
          (addif (sale-col used-columns)   (make-cell sale))
          (addif (tax-col used-columns)    (make-cell tax))
          (addif (debit-col used-columns)  (make-cell debit))
          (addif (credit-col used-columns) (make-cell credit))
          (addif (bal-col used-columns)    (make-cell total))
          (addif (< 0 rhs-cols)
                 (gnc:make-html-table-cell/size
                  1 (+ mid-span rhs-cols)
                  (and add-derived-amounts-disclaimer?
                       (gnc:make-html-text
                        (G_ "* Amounts denoted thus are derived from, \
and do not match the transaction."))))))))

    ;; print grand total
    (if (bal-col used-columns)
        (gnc:html-table-append-row/markup!
         table "grand-total"
         (append
          (addif (< 1 grand-span)
                 (gnc:make-html-table-cell/markup
                  "total-label-cell"
                  (if (negative? total)
                      (G_ "Total Credit")
                      (G_ "Total Due"))))
          (addif (< 1 grand-span)
                 (gnc:make-html-table-cell/size/markup
                  1 (1- grand-span)
                  "total-number-cell"
                  (gnc:make-gnc-monetary currency total)))
          (addif (< 0 rhs-cols)
                 (gnc:make-html-table-cell/size 1 (+ mid-span rhs-cols) #f)))))

    (unless (null? invalid-splits)
      (gnc:html-table-append-row/markup!
       table "grand-total"
       (list (gnc:make-html-table-cell/size
              1 (+ grand-span mid-span rhs-cols)
              (gnc:make-html-text
               (G_ "Please note some transactions were not processed")
               (gnc:html-markup-ol
                (map
                 (match-lambda
                   ((split txt)
                    (gnc:html-markup-anchor (gnc:split-anchor-text split) txt)))
                 invalid-splits)))))))

    ;; print aging table
    (gnc:html-table-append-row/markup!
     table "grand-total"
     (list (gnc:make-html-table-cell/size
            1 (+ grand-span mid-span rhs-cols)
            (make-aging-table splits
                              end-date
                              payable? date-type currency)))))

  (define (add-balance-row odd-row? total)
    (add-row table odd-row? used-columns start-date #f "" (G_ "Balance") "" #f
             currency total #f #f #f #f #f
             link-option (case link-option
                           ((none) '(()))
                           ((simple) '((#f)))
                           ((detailed) (list (make-link-blank))))))

  (define (make-invoice->payments-table invoice)
    (let ((lot (gncInvoiceGetPostedLot invoice)))
      (let lp ((lot-splits (gnc-lot-get-split-list lot))
               (result '()))
        (cond
         ;; Finished result rows. Display them, and add Outstanding if
         ;; invoice still not completely paid.
         ((null? lot-splits)
          (reverse
           (if (gncInvoiceIsPaid invoice)
               result
               (cons (make-link-desc-amount
                      (G_ "UNPAID")
                      (gnc:make-gnc-monetary
                       currency (AP-negate (gnc-lot-get-balance lot)))
                      (gncInvoiceReturnGUID invoice))
                     result))))

         ;; this is invoice posting split. skip. has no payment data.
         ((equal? (xaccSplitGetParent (car lot-splits))
                  (gncInvoiceGetPostedTxn invoice))
          (lp (cdr lot-splits) result))

         ;; this is an invoice payment split (reduces the lot).
         (else
          (let* ((lot-split (car lot-splits))
                 (lot-txn (xaccSplitGetParent lot-split)))

            ;; each invoice payment split's peer splits are analysed.
            (let lp1 ((lot-txn-splits (xaccTransGetSplitList lot-txn))
                      (non-document '())
                      (result result))
              (cond

               ;; finished. loop up, adding single row with non-document
               ((null? lot-txn-splits)
                (lp (cdr lot-splits)
                    (if (null? non-document)
                        result
                        (cons (make-link-data
                               (qof-print-date (xaccTransGetDate lot-txn))
                               (split->reference lot-split)
                               (split->type-str lot-split payable?)
                               (splits->desc non-document)
                               (gnc:make-html-text (split->anchor lot-split #f))
                               (list->cell
                                (map (lambda (s) (split->anchor s #t)) non-document))
                               (gncTransGetGUID lot-txn))
                              result))))

               ;; this payment's peer split has same sign as the
               ;; payment split. ignore.
               ((sign-equal? (xaccSplitGetAmount (car lot-txn-splits))
                             (xaccSplitGetAmount lot-split))
                (lp1 (cdr lot-txn-splits) non-document result))

               ;; this payment's peer APAR split is a document lot
               ;; reducing split.
               ((lot-split->posting-split (car lot-txn-splits)) =>
                (lambda (posting-split)
                  (let* ((lot-txn-split (car lot-txn-splits))
                         (posting-txn (xaccSplitGetParent posting-split))
                         (document (gncInvoiceGetInvoiceFromTxn posting-txn)))
                    (lp1 (cdr lot-txn-splits)
                         non-document
                         (cons (make-link-data
                                (qof-print-date (xaccTransGetDate posting-txn))
                                (split->reference posting-split)
                                (split->type-str posting-split payable?)
                                (splits->desc (list posting-split))
                                (gnc:make-html-text (split->anchor lot-split #f))
                                (gnc:make-html-text (split->anchor posting-split #f))
                                (gncInvoiceReturnGUID document))
                               result)))))

               ;; this payment's peer split can't find document. this
               ;; is a regular payment or an old link txn. accumulate.
               (else
                (lp1 (cdr lot-txn-splits)
                     (cons (car lot-txn-splits) non-document)
                     result))))))))))

  (define (make-payment->invoices-list txn)
    (list
     (list
      (apply
       gnc:make-html-text
       (map
        (lambda (inv-split-pair)
          (invoice->anchor (car inv-split-pair)))
        (vector-ref (gnc:payment-txn->payment-info txn) 0))))))

  (define (make-payment->payee-table txn payable?)

    (define (invoices-list invoice-split-pairs)
      (let lp ((invoice-split-pairs invoice-split-pairs)
               (result '()))
        (match invoice-split-pairs
          (() (reverse result))
          (((inv . APAR-split) . rest)
           (let* ((posting-split (lot-split->posting-split APAR-split)))
             (lp rest
                 (cons (make-link-data
                        (qof-print-date (gncInvoiceGetDatePosted inv))
                        (gnc:make-html-text (invoice->anchor inv))
                        (gncInvoiceGetTypeString inv)
                        (splits->desc (list APAR-split))
                        (gnc:make-html-text (split->anchor APAR-split #t))
                        (gnc:make-html-text (split->anchor posting-split #f))
                        (gncInvoiceReturnGUID inv))
                       result)))))))

    (define (payments-list opposing-splits)
      (let lp1 ((opposing-splits opposing-splits)
                (pmt-list '()))
        (match opposing-splits
          (() (reverse pmt-list))
          (((s partial-amount derived?). rest)
           (when derived?
             (set! add-derived-amounts-disclaimer? #t))
           (lp1 rest
                (cons
                 (make-link-data
                  (qof-print-date (xaccTransGetDate (xaccSplitGetParent s)))
                  (split->reference s)
                  (split->type-str s payable?)
                  (splits->desc (list s))
                  (gnc:make-html-text
                   (if derived? "* " "")
                   (gnc:html-markup-anchor
                    (gnc:split-anchor-text s)
                    (gnc:monetary->string
                     (gnc:make-gnc-monetary currency partial-amount))))
                  (gnc:make-html-text (split->anchor s #f))
                  (gncTransGetGUID (xaccSplitGetParent s)))
                 pmt-list))))))

    (define (overpayment-list overpayment)
      (if (zero? overpayment)
          '()
          (list (make-link-desc-amount
                 (G_ "Pre-Payment")
                 (gnc:make-html-text
                  (gnc:monetary->string
                   (gnc:make-gnc-monetary
                    currency ((if payable? + -) overpayment))))
                 (gncTransGetGUID txn)))))

    (let* ((payment-info (gnc:payment-txn->payment-info txn))
           (invoices-result (invoices-list (vector-ref payment-info 0)))
           (payment-result (payments-list (vector-ref payment-info 1)))
           (overpayment-result (overpayment-list (vector-ref payment-info 2))))
      (append invoices-result payment-result overpayment-result)))

  (define (amount->anchor split amount)
    (gnc:make-html-text
     (gnc:html-markup-anchor
      (gnc:split-anchor-text split)
      (gnc:make-gnc-monetary currency amount))))

  (define seen-txns (make-hash-table))

  (let lp ((printed? #f)
           (odd-row? #t)
           (splits splits)
           (invalid-splits '())
           (total 0)
           (debit 0)
           (credit 0)
           (tax 0)
           (sale 0))

    (cond

     ((null? splits)
      ;;Balance row may not have been added if all transactions were before
      ;;start-date (and no other rows would be added either) so add it now
      (when (and (not printed?) (bal-col used-columns) (not (zero? total)))
        (add-balance-row odd-row? total))
      (print-totals total debit credit tax sale invalid-splits)
      (gnc:html-table-set-style!
       table "table"
       'attribute (list "border" 1)
       'attribute (list "cellspacing" 0)
       'attribute (list "cellpadding" 4))
      table)

     ((hash-ref seen-txns (xaccSplitGetParent (car splits)))
      (lp printed? odd-row? (cdr splits) invalid-splits total debit credit tax sale))

     ;; not an invoice/payment. skip transaction.
     ((not (or (txn-is-invoice? (xaccSplitGetParent (car splits)))
               (txn-is-payment? (xaccSplitGetParent (car splits)))))
      (lp printed? odd-row? (cdr splits) invalid-splits total debit credit tax sale))

     ;; invalid case: txn-type-invoice but no associated invoice, nor lot
     ((let* ((txn (xaccSplitGetParent (car splits)))
             (invoice (gncInvoiceGetInvoiceFromTxn txn)))
        (and (txn-is-invoice? txn)
             (or (null? invoice)
                 (null? (gncInvoiceGetPostedLot invoice)))))
      (gnc:warn "sanity check fail " (gnc:strify (car splits)))
      (lp printed? odd-row? (cdr splits)
          (cons (list (car splits) "Transaction has type invoice but no owner or lot")
                invalid-splits)
          total debit credit tax sale))

     ;; txn-date < start-date. skip display, accumulate amounts
     ((< (xaccTransGetDate (xaccSplitGetParent (car splits))) start-date)
      (let* ((txn (xaccSplitGetParent (car splits)))
             (value (AP-negate (xaccTransGetAccountAmount txn acc))))
        (hash-set! seen-txns txn #t)
        (lp printed? odd-row? (cdr splits) invalid-splits (+ total value)
            debit credit tax sale)))

     ;; if balance row hasn't been rendered, consider
     ;; adding here.  skip if value=0.
     ((not printed?)
      (let ((print? (and (bal-col used-columns) (not (zero? total)))))
        (if print? (add-balance-row odd-row? total))
        (lp #t (not print?) splits invalid-splits total debit credit tax sale)))

     ;; start printing txns.
     ((txn-is-invoice? (xaccSplitGetParent (car splits)))
      (hash-set! seen-txns (xaccSplitGetParent (car splits)) #t)
      (let* ((split (car splits))
             (txn (xaccSplitGetParent split))
             (date (xaccTransGetDate txn))
             (orig-value (xaccTransGetAccountAmount txn acc))
             (value (AP-negate orig-value))
             (invoice (gncInvoiceGetInvoiceFromTxn txn)))

        (define (CN-negate fn)
          (if (gncInvoiceGetIsCreditNote invoice) (- (fn invoice)) (fn invoice)))

        (add-row
         table odd-row? used-columns date (gncInvoiceGetDateDue invoice)
         (split->reference split)
         (split->type-str split payable?)
         (splits->desc (list split))
         (and (not (string-null? (gncInvoiceGetDocLink invoice))) invoice)
         currency (+ total value)
         (and (>= orig-value 0) (amount->anchor split orig-value))
         (and (< orig-value 0) (amount->anchor split (- orig-value)))
         (CN-negate gncInvoiceGetTotalSubtotal) (CN-negate gncInvoiceGetTotalTax)
         (gncInvoiceReturnGUID invoice)
         link-option
         (case link-option
           ((simple) (list (list (and (gncInvoiceIsPaid invoice) (G_ "Paid")))))
           ((detailed) (make-invoice->payments-table invoice))
           (else '(()))))

        (lp printed? (not odd-row?) (cdr splits) invalid-splits (+ total value)
            (if (< 0 orig-value) (+ debit orig-value) debit)
            (if (< 0 orig-value) credit (- credit orig-value))
            (+ tax (CN-negate gncInvoiceGetTotalTax))
            (+ sale (CN-negate gncInvoiceGetTotalSubtotal)))))

     ((txn-is-payment? (xaccSplitGetParent (car splits)))
      (hash-set! seen-txns (xaccSplitGetParent (car splits)) #t)
      (let* ((split (car splits))
             (txn (xaccSplitGetParent split))
             (date (xaccTransGetDate txn))
             (amt/next-pair
              (let lp1 ((splits splits) (acc 0) (non-txn '()))
                (match splits
                  (() (cons acc (reverse non-txn)))
                  (((? (lambda (s) (equal? (xaccSplitGetParent s) txn)) head) . tail)
                   (lp1 tail (+ (xaccSplitGetAmount head) acc) non-txn))
                  ((head . tail) (lp1 tail acc (cons head non-txn))))))
             (orig-value (car amt/next-pair))
             (value (AP-negate orig-value)))

        (add-row
         table odd-row? used-columns date #f
         (split->reference split)
         (split->type-str split payable?)
         (splits->desc (xaccTransGetAPARAcctSplitList txn #t) #t)
         #f currency (+ total value)
         (and (>= orig-value 0) (amount->anchor split orig-value))
         (and (< orig-value 0) (amount->anchor split (- orig-value)))
         #f #f
         (gncTransGetGUID txn)
         link-option
         (case link-option
           ((simple) (make-payment->invoices-list txn))
           ((detailed) (make-payment->payee-table txn payable?))
           (else '(()))))

        (lp printed? (not odd-row?) (cdr amt/next-pair) invalid-splits (+ total value)
            (if (< 0 orig-value) (+ debit orig-value) debit)
            (if (< 0 orig-value) credit (- credit orig-value))
            tax
            sale))))))

(define (options-generator owner-type)

  (define gnc:*report-options* (gnc:new-options))

  (define (gnc:register-inv-option new-option)
    (gnc:register-option gnc:*report-options* new-option))

  (gnc:register-inv-option
   (gnc:make-owner-option
    owner-page (owner-string owner-type) "v"
    (N_ "The company for this report.")
    (lambda () '()) #f owner-type))

  (gnc:options-add-date-interval!
   gnc:*report-options* gnc:pagename-general
   optname-from-date optname-to-date "a")

  ;; Use a default report date of 'today'
  (gnc:option-set-default-value
   (gnc:lookup-option gnc:*report-options* gnc:pagename-general optname-to-date)
   (cons 'relative 'today))

  (gnc:register-inv-option
   (gnc:make-simple-boolean-option
    (N_ "Display Columns") date-header
    "b" (N_ "Display the transaction date?") #t))

  (gnc:register-inv-option
   (gnc:make-simple-boolean-option
    (N_ "Display Columns") due-date-header
    "c" (N_ "Display the transaction date?") #t))

  (gnc:register-inv-option
   (gnc:make-simple-boolean-option
    (N_ "Display Columns") reference-header
    "d" (N_ "Display the transaction reference?") #t))

  (gnc:register-inv-option
   (gnc:make-simple-boolean-option
    (N_ "Display Columns") type-header
    "g" (N_ "Display the transaction type?") #t))

  (gnc:register-inv-option
   (gnc:make-simple-boolean-option
    (N_ "Display Columns") desc-header
    "ha" (N_ "Display the transaction description?") #t))

  (gnc:register-inv-option
   (gnc:make-simple-boolean-option
    (N_ "Display Columns") sale-header
    "haa" (N_ "Display the sale amount column?") #f))

  (gnc:register-inv-option
   (gnc:make-simple-boolean-option
    (N_ "Display Columns") tax-header
    "hab" (N_ "Display the tax column?") #f))

  (gnc:register-inv-option
   (gnc:make-simple-boolean-option
    (N_ "Display Columns") debit-header
    "hac" (N_ "Display the period debits column?") #t))

  (gnc:register-inv-option
   (gnc:make-simple-boolean-option
    (N_ "Display Columns") credit-header
    "had" (N_ "Display the period credits column?") #t))

  (gnc:register-inv-option
   (gnc:make-simple-boolean-option
    (N_ "Display Columns") balance-header
    "hb" (N_ "Display a running balance?") #t))

  (gnc:register-inv-option
   (gnc:make-multichoice-option
    (N_ "Display Columns") linked-txns-header
    "hc"
    (string-join
     (list
      (G_ "Show linked transactions")
      (G_ "Linked transactions are hidden.")
      (G_ "Invoices show if paid, payments show invoice numbers.")
      (G_ "Invoices show list of payments, payments show list of invoices and amounts."))
      "\n* ")
    'none
    (list (vector 'none (N_ "Disabled"))
          (vector 'simple (N_ "Simple"))
          (vector 'detailed (N_ "Detailed")))))

  (gnc:register-inv-option
   (gnc:make-simple-boolean-option
    (N_ "Display Columns") doclink-header
    "hd" (N_ "Display document link?") #f))

  (gnc:register-inv-option
   (gnc:make-multichoice-option
    gnc:pagename-general optname-date-driver "k"
    (N_ "Leading date.") 'duedate
    (list
     (vector 'duedate (N_ "Due Date"))
     (vector 'postdate (N_ "Post Date")))))

  (gnc:options-set-default-section gnc:*report-options* "General")

  gnc:*report-options*)

(define (setup-query q owner accounts end-date job?)
  (let ((guid (gncOwnerReturnGUID (if job? owner (gncOwnerGetEndOwner owner))))
        (last-param (if job? QOF-PARAM-GUID OWNER-PARENTG)))
    (qof-query-add-guid-match
     q (list SPLIT-TRANS INVOICE-FROM-TXN INVOICE-OWNER last-param)
     guid QOF-QUERY-OR)
    (qof-query-add-guid-match
     q (list SPLIT-LOT OWNER-FROM-LOT last-param)
     guid QOF-QUERY-OR)
    (qof-query-add-guid-match
     q (list SPLIT-LOT INVOICE-FROM-LOT INVOICE-OWNER last-param)
     guid QOF-QUERY-OR)
    (xaccQueryAddAccountMatch q accounts QOF-GUID-MATCH-ANY QOF-QUERY-AND)
    (xaccQueryAddDateMatchTT q #f end-date #t end-date QOF-QUERY-AND)
    (qof-query-set-book q (gnc-get-current-book))
    (qof-query-set-sort-order q (list SPLIT-TRANS TRANS-DATE-POSTED) '() '())
    q))

(define (make-owner-table owner)
  (let ((table (gnc:make-html-table)))
    (gnc:html-table-set-style!
     table "table"
     'attribute (list "border" 0)
     'attribute (list "cellspacing" 0)
     'attribute (list "cellpadding" 0)
     'attribute (list "valign" "top"))
    (gnc:html-table-append-row!
     table (gnc:multiline-to-html-text (gnc:owner-get-name-and-address-dep owner)))
    table))

(define (make-myname-table book date-format)
  (let* ((table (gnc:make-html-table))
         (name (gnc:company-info book gnc:*company-name*))
         (addy (gnc:company-info book gnc:*company-addy*)))

    (gnc:html-table-set-style!
     table "table"
     'attribute (list "border" 0)
     'attribute (list "align" "right")
     'attribute (list "valign" "top")
     'attribute (list "cellspacing" 0)
     'attribute (list "cellpadding" 0))

    (when name
      (gnc:html-table-append-row! table (list name)))
    (when addy
      (gnc:html-table-append-row! table (gnc:multiline-to-html-text addy)))
    (gnc:html-table-append-row!
     table (list (gnc-print-time64 (gnc:get-today) date-format)))
    table))

(define (make-break! document)
  (gnc:html-document-add-object!
   document
   (gnc:make-html-text
    (gnc:html-markup-br))))

(define (reg-renderer report-obj type)
  (define options (gnc:report-options report-obj))
  (define (opt-val section name)
    (gnc:option-value
     (gnc:lookup-option options section name)))

  (let* ((start-date (gnc:time64-start-day-time
                      (gnc:date-option-absolute-time
                       (opt-val gnc:pagename-general optname-from-date))))
         (end-date (gnc:time64-end-day-time
                    (gnc:date-option-absolute-time
                     (opt-val gnc:pagename-general optname-to-date))))
         (book (gnc-get-current-book))
         (date-format (gnc:options-fancy-date (gnc-get-current-book)))
         (used-columns (build-column-used options))
         (link-option
          (gnc:option-value
           (gnc:lookup-option options "Display Columns" linked-txns-header)))
         (owner-descr (owner-string type))
         (date-type (opt-val gnc:pagename-general optname-date-driver))
         (owner (opt-val owner-page owner-descr))
         (acct-type (if (eqv? (gncOwnerGetType (gncOwnerGetEndOwner owner))
                              GNC-OWNER-CUSTOMER)
                        ACCT-TYPE-RECEIVABLE ACCT-TYPE-PAYABLE))
         (accounts (filter (lambda (a) (eqv? (xaccAccountGetType a) acct-type))
                           (gnc-account-get-descendants-sorted
                            (gnc-get-current-root-account))))
         (payable? (eqv? ACCT-TYPE-PAYABLE acct-type))
         (query (qof-query-create-for-splits))
         (document (gnc:make-html-document))
         (table (gnc:make-html-table))
         (section-headings (make-section-heading-list used-columns owner-descr))
         (headings (make-heading-list used-columns link-option))
         (report-title (string-append (G_ owner-descr) " " (G_ "Report"))))

    (cond
     ((not (gncOwnerIsValid owner))
      (gnc:html-document-add-object!
       document (gnc:html-make-generic-warning
                 report-title (gnc:report-id report-obj)
                 (cadr (get-info type)) (caddr (get-info type)))))

     ((null? accounts)
      (gnc:html-document-add-object!
       document
       (gnc:html-make-generic-warning
        (string-append report-title ": " (gncOwnerGetName owner))
        (gnc:report-id report-obj)
        (G_ "No valid account found")
        (G_ "This report requires a valid AP/AR account to be available."))))

     (else
      (setup-query query owner accounts end-date (eqv? GNC-OWNER-JOB type))

      (let ((splits (qof-query-run query)))
        (qof-query-destroy query)

        (gnc:html-document-set-headline!
         document (gnc:html-markup
                   "span" report-title ": "
                   (gnc:html-markup-anchor
                    (if (eqv? GNC-OWNER-JOB type)
                        (gnc:job-anchor-text (gncOwnerGetJob owner))
                        (gnc:owner-anchor-text owner))
                    (gncOwnerGetName owner))))

        (cond
         ((null? splits)

          (gnc:html-document-add-object!
           document
           (gnc:make-html-text
            (gnc:html-markup-h3 (G_ "No transactions found."))
            (gnc:html-markup-p (G_ "No matching transactions found"))
            (gnc:html-make-options-link (gnc:report-id report-obj)))))

         (else
          ;; loops in 2 passes: 1st loop. for each APAR account, filter
          ;; splits into each account. accumulate non-null results into
          ;; accounts-and-splits accumulator.
          (let loop ((accounts accounts)
                     (accounts-and-splits '())
                     (splits splits))
            (cond
             ((null? accounts)

              ;; 2nd loop: for-each accounts-and-splits accumulator, add
              ;; owner-txns into the html-table. only show header if >1
              ;; account has splits.
              (for-each
               (lambda (acc-splits-pair)
                 (let* ((account (car acc-splits-pair))
                        (splits (cdr acc-splits-pair)))

                   (when (> (length accounts-and-splits) 1)
                     (gnc:html-table-append-row!
                      table (gnc:make-html-table-cell/size
                             1 (length headings)
                             (gnc:make-html-text
                              (gnc:html-markup-h3
                               (string-append (G_ "Account") ": "
                                              (xaccAccountGetName account)))))))

                   (add-owner-table table splits account start-date end-date
                                    date-type used-columns payable? link-option)))
               accounts-and-splits))

             (else
              ;; each 1st loop will slice splits into account-splits and
              ;; non-account splits, add to accounts-and-splits; and send
              ;; the non-account splits to be processed in the next loop
              ;; iteration.
              (let-values (((acc-splits other-acc-splits)
                            (partition
                             (lambda (split)
                               (equal? (car accounts) (xaccSplitGetAccount split)))
                             splits)))

                (loop (cdr accounts)
                      (if (null? acc-splits)
                          accounts-and-splits
                          (cons (cons (car accounts) acc-splits)
                                accounts-and-splits))
                      other-acc-splits)))))

          (gnc:html-document-add-object!
           document (make-myname-table book date-format))

          (gnc:html-document-add-object!
           document (make-owner-table owner))

          (gnc:html-document-add-object!
           document (gnc:make-html-text
                     (string-append (G_ "Date Range") ": " (qof-print-date start-date)
                                    " - " (qof-print-date end-date))))

          (make-break! document)

          (gnc:html-table-set-multirow-col-headers!
           table
           (if (eq? link-option 'detailed)
               (list section-headings headings)
               (list headings)))

          (gnc:html-document-add-object! document table)

          (gnc:html-document-add-object! document javascript))))))

    document))

(define (customer-renderer obj)
  (reg-renderer obj GNC-OWNER-CUSTOMER))

(define (vendor-renderer  obj)
  (reg-renderer obj GNC-OWNER-VENDOR))

(define (employee-renderer obj)
  (reg-renderer obj GNC-OWNER-EMPLOYEE))

(define (job-renderer obj)
  (reg-renderer obj GNC-OWNER-JOB))

(define customer-report-guid "c146317be32e4948a561ec7fc89d15c1")
(define vendor-report-guid "d7d1e53505ee4b1b82efad9eacedaea0")
(define employee-report-guid "08ae9c2e884b4f9787144f47eacd7f44")

(gnc:define-report
 'version 1
 'name (N_ "Customer Report")
 'report-guid customer-report-guid
 'menu-path (list gnc:menuname-business-reports)
 'options-generator (lambda () (options-generator GNC-OWNER-CUSTOMER))
 'renderer customer-renderer
 'in-menu? #t)

(gnc:define-report
 'version 1
 'name (N_ "Vendor Report")
 'report-guid vendor-report-guid
 'menu-path (list gnc:menuname-business-reports)
 'options-generator (lambda () (options-generator GNC-OWNER-VENDOR))
 'renderer vendor-renderer
 'in-menu? #t)

(gnc:define-report
 'version 1
 'name (N_ "Employee Report")
 'report-guid employee-report-guid
 'menu-path (list gnc:menuname-business-reports)
 'options-generator (lambda () (options-generator GNC-OWNER-EMPLOYEE))
 'renderer employee-renderer
 'in-menu? #t)

(gnc:define-report
 'version 1
 'name (N_ "Job Report")
 'report-guid "5518ac227e474f47a34439f2d4d049de"
 'menu-path (list gnc:menuname-business-reports)
 'options-generator (lambda () (options-generator GNC-OWNER-JOB))
 'renderer job-renderer
 'in-menu? #t)


(define (owner-report-create-internal report-guid owner owner-type enddate)
  (let* ((options (gnc:make-report-options report-guid))
         (owner-op (gnc:lookup-option options owner-page (owner-string owner-type)))
         (date-op (gnc:lookup-option options gnc:pagename-general optname-to-date)))

    (gnc:option-set-value owner-op owner)
    (when enddate
      (gnc:option-set-value date-op (cons 'absolute enddate)))
    (gnc:make-report report-guid options)))

(define (owner-report-create-with-enddate owner account enddate)
  ;; note account isn't actually used
  (define guid-alist
    (list (cons GNC-OWNER-CUSTOMER customer-report-guid)
          (cons GNC-OWNER-VENDOR vendor-report-guid)
          (cons GNC-OWNER-EMPLOYEE employee-report-guid)))
  (and-let* ((type (gncOwnerGetType (gncOwnerGetEndOwner owner)))
             (guid (assv-ref guid-alist type)))
    (owner-report-create-internal guid owner type enddate)))

(define (owner-report-create owner account)
  (issue-deprecation-warning "owner-report-create is not used anymore. call owner-report-create-with-enddate instead")
  (owner-report-create-with-enddate owner account #f))

(define (gnc:owner-report-create-internal
         account split query journal? double? title debit-string credit-string)
  (let* ((split->owner (gnc:make-split->owner))
         (owner (split->owner split)))
    (if (gncOwnerIsValid owner)
        (owner-report-create-with-enddate owner account #f)
        -1)))

(gnc:register-report-hook ACCT-TYPE-RECEIVABLE #t gnc:owner-report-create-internal)
(gnc:register-report-hook ACCT-TYPE-PAYABLE #t gnc:owner-report-create-internal)
(export owner-report-create)            ;deprecate
(export owner-report-create-with-enddate)
