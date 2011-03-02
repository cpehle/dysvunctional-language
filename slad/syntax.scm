(declare (usual-integrations))
;;;; Abstract Syntax

(define ((tagged-list? tag) thing)
  (and (pair? thing)
       (eq? (car thing) tag)))

(define (constant? thing)
  (or (number? thing)
      (boolean? thing)
      (slad-bundle? thing)
      (null? thing)
      (quoted? thing)))

(define (constant-value thing)
  (if (quoted? thing)
      (cadr thing)
      thing))

(define quoted? (tagged-list? 'quote))

(define (variable? thing)
  (symbol? thing))

(define variable<? symbol<?)

(define definition? (tagged-list? 'define))

(define (normalize-definition definition)
  (cond ((not (definition? definition))
	 (error "Trying to normalize a non-definition" definition))
	((pair? (cadr definition))
	 (normalize-definition
	  `(define ,(caadr definition)
	     (lambda ,(cdadr definition)
	       ,@(cddr definition)))))
	(else definition)))

(define (definiendum definition)
  (cadr (normalize-definition definition)))

(define (definiens definition)
  (caddr (normalize-definition definition)))

(define pair-form? (tagged-list? 'cons))
(define car-subform cadr)
(define cdr-subform caddr)
(define (make-pair-form car-subform cdr-subform)
  `(cons ,car-subform ,cdr-subform))

(define lambda-form? (tagged-list? 'lambda))
(define lambda-formal cadr)
(define lambda-body caddr)
(define (make-lambda-form formal body)
  `(lambda ,formal ,body))

(define (application? thing)
  (and (pair? thing)
       (not (pair-form? thing))
       (not (lambda-form? thing))))
(define operator-subform car)
(define operand-subform cadr)
(define (make-application operator-form operand-form)
  `(,operator-form ,operand-form))
