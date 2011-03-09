(declare (usual-integrations))
;;;; Post processing

;;; The post-processing stage consists of several sub-stages.  They
;;; need to be done in order, but you can invoke any subsequence to
;;; see the effect of doing only that level of post-processing.
;;; We have:
;;; - STRUCTURE-DEFINITIONS->VECTORS
;;;   Replace DEFINE-STRUCTURE with explicit vectors.
;;; - INLINE
;;;   Inline non-recursive function definitions.
;;; - SCALAR-REPLACE-AGGREGATES
;;;   Replace aggregates with scalars at procedure boundaries.
;;;   This relies on argument-type annotations being emitted by the
;;;   code generator.
;;; - STRIP-ARGUMENT-TYPES
;;;   Remove argument-type annotations, if they have been emitted by
;;;   the code generator (because SCALAR-REPLACE-AGGREGATES is the
;;;   only thing that needs them).
;;; - TIDY
;;;   Clean up and optimize locally by term-rewriting.

(define (prettify-compiler-output output)
  (if (list? output)
      (tidy
       (strip-argument-types
	(scalar-replace-aggregates
	 (inline
	  (structure-definitions->vectors
	   output)))))
      output))

(define (compile-to-scheme program)
  (prettify-compiler-output
   (analyze-and-generate-with-type-declarations program)))

;;; Don't worry about the rule-based term-rewriting system that powers
;;; this.  That is its own pile of stuff, good for a few lectures of
;;; Sussman's MIT class Adventures in Advanced Symbolic Programming.
;;; It works, and it's very good for peephole manipulations of
;;; structured expressions (like the output of the VL code generator).
;;; If you really want to see it, though, it's included in
;;; support/rule-system.

;;; Rules for the term-rewriting system consist of a pattern to try to
;;; match and an expression to evaluate to compute a replacement for
;;; that match should a match be found.  Patterns match themselves;
;;; the construct (? name) introduces a pattern variable named name;
;;; the construct (? name ,predicate) is a restricted pattern variable
;;; which only matches things the predicate accepts; the construct (??
;;; name) introduces a sublist pattern variable.  The pattern matcher
;;; will search through possible lengths of sublists to find a match.
;;; Repeated pattern variables must match equal structures in all the
;;; corresponding places.

;;; A rule by itself is a one-argument procedure that tries to match
;;; its pattern.  If the match succeeds, the rule will evaluate the
;;; the replacement expression in an environment where the pattern
;;; variables are bound to the things they matched and return the
;;; result.  If the replacement expression returns #f, that tells the
;;; matcher to backtrack and look for another match.  If the match
;;; fails, the rule will return #f.

;;; A rule simplifier has a set of rules, and applies them to every
;;; subexpression of the input expression repeatedly until the result
;;; settles down.

;;;; Turning record structures into vectors

;;; Just replace every occurrence of DEFINE-STRUCTURE with the
;;; corresponding pile of vector operations.  Also need to make sure
;;; that the argument types declarations, if any, all say VECTOR
;;; rather than whatever the name of the structure used to be.

(define (structure-definition? form)
  (and (pair? form)
       (eq? (car form) 'define-structure)))

(define (expand-if-structure-definition form)
  (if (structure-definition? form)
      (let ((name (cadr form))
	    (fields (cddr form)))
	`((define ,(symbol 'make- name) vector)
	  ,@(map (lambda (field index)
		   `(define (,(symbol name '- field) thing)
		      (vector-ref thing ,index)))
		 fields
		 (iota (length fields)))))
      (list form)))

(define (structure-definitions->vectors forms)
  (let ((structure-names
	 (map cadr (filter structure-definition? forms))))
    (define (fix-argument-types forms)
      (let loop ((forms forms)
		 (structure-names structure-names))
	(if (null? structure-names)
	    forms
	    (loop (replace-free-occurrences
		   (car structure-names) 'vector forms)
		  (cdr structure-names)))))
    (fix-argument-types
     (append-map expand-if-structure-definition forms))))

;;;; Scalar replacement of aggregates

;;; If some procedure accepts a structured argument, it can be
;;; converted into accepting the fields of that argument instead, as
;;; long as all the call sites are changed to pass the fields instead
;;; of the structure at the same time.  This piece of code does this
;;; in a way that is local to the definitions and call sites --- the
;;; new procedure definition just reconstructs the structure from the
;;; passed arguments, and the new call sites just extract the fields
;;; from the structure they would have passed.  However, once this
;;; tranformation is done, further local simplifications done by TIDY
;;; will have the effect of eliminating those structures completely.

;;; This process relies on the code generator having emitted argument
;;; type declarations.  If there are no argument type declarations,
;;; nothing will happen.

;;; The key trick in how this is done is SRA-DEFINITION-RULE, which
;;; pattern matches on a definition with an argument type declaration,
;;; and, if the definition accepted a structured argument, returns a
;;; rewritten definition and a rule for transforming the call sites.

(define (cons-or-vector? thing)
  (or (eq? thing 'cons)
      (eq? thing 'vector)))

(define sra-definition-rule
  (rule
   `(define ((? name) (?? formals1) (? formal) (?? formals2))
      (argument-types
       (?? stuff1)
       ((? formal) ((? constructor ,cons-or-vector?)
		    (?? slot-shapes)))
       (?? stuff2))
      (?? body))
   (let ((slot-names (map (lambda (shape)
			    (make-name (symbol formal '-)))
			  slot-shapes))
	 (arg-index (length formals1))
	 (num-slots (length slot-shapes))
	 (arg-count (+ (length formals1) 1 (length formals2))))
     (cons (sra-call-site-rule
	    name constructor arg-index num-slots arg-count)
	   `(define (,name ,@formals1 ,@slot-names ,@formals2)
	      (argument-types
	       ,@stuff1
	       ,@(map list slot-names slot-shapes)
	       ,@stuff2)
	      (let ((,formal (,constructor ,@slot-names)))
		,@body))))))

(define (sra-call-site-rule
	 operation-name constructor arg-index num-slots arg-count)
  (rule
   `(,operation-name (?? args))
   (and (= (length args) arg-count)
	(let ((args1 (take args arg-index))
	      (arg (list-ref args arg-index))
	      (args2 (drop args (+ arg-index 1)))
	      (temp-name (make-name 'temp-)))
	  `(let ((,temp-name ,arg))
	     (,operation-name
	      ,@args1
	      ,@(call-site-replacement temp-name constructor num-slots)
	      ,@args2))))))

(define (call-site-replacement temp-name constructor-type count)
  (if (eq? 'cons constructor-type)
      `((car ,temp-name) (cdr ,temp-name))
      (map (lambda (index)
	     `(vector-ref ,temp-name ,index))
	   (iota count))))

;;; The actual SCALAR-REPLACE-AGGREGATES procedure just tries
;;; SRA-DEFINITION-RULE on all the possible definitions as many times
;;; as it does something.  Whenever SRA-DEFINITION-RULE rewrites a
;;; definition, SCALAR-REPLACE-AGGREGATES applies the resulting
;;; sra-call-site-rule to rewrite all the call sites.  The only tricky
;;; bit is to make sure not to apply the sra-call-site-rule to the
;;; formal parameter list of the definition just rewritten, because it
;;; will match it and screw it up.

(define (scalar-replace-aggregates forms)
  (define (do-sra-definition sra-result done rest)
    (let ((sra-call-site-rule (car sra-result))
	  (replacement-form (cdr sra-result)))
      (let ((sra-call-sites (recursively-try-once sra-call-site-rule)))
	(let ((fixed-replacement-form
	       `(,(car replacement-form) ,(cadr replacement-form)
		 ,(caddr replacement-form)
		 ,(sra-call-sites (cadddr replacement-form))))
	      (fixed-done (sra-call-sites (reverse done)))
	      (fixed-rest (sra-call-sites rest)))
	  (append fixed-done (list fixed-replacement-form) fixed-rest)))))
  (let loop ((forms forms))
    (let scan ((done '()) (forms forms))
      (if (null? forms)
	  (reverse done)
	  (let ((sra-attempt (sra-definition-rule (car forms))))
	    (if sra-attempt
		(loop (do-sra-definition sra-attempt done (cdr forms)))
		(scan (cons (car forms) done) (cdr forms))))))))

;;; Getting rid the argument-types declarations once we're done with
;;; them is easy.

(define strip-argument-types
  (rule-simplifier
   (list
    (rule `(begin (define-syntax argument-types (?? etc))
		  (?? stuff))
	  `(begin
	     ,@stuff))
    (rule `(define (? formals)
	     (argument-types (?? etc))
	     (?? body))
	  `(define ,formals
	     ,@body)))))
;;;; Inlining procedure definitions

;;; Every procedure that does not call itself can be inlined.  To do
;;; that, just replace references to that procedure's name with
;;; anonymous lambda expressions that do the same job.  The
;;; term-rewriter TIDY will clean up the mess nicely.

(define (inline forms)
  (define (non-self-calling? defn)
    (= 0 (count-in-tree (definiendum defn) (definiens defn))))
  (define (inline-defn defn forms)
    (let ((defn (strip-argument-types defn)))
      (replace-free-occurrences (definiendum defn) (definiens defn) forms)))
  (let loop ((forms forms))
    (let scan ((done '()) (forms forms))
      (cond ((null? forms) (reverse done))
	    ((and (definition? (car forms))
		  (non-self-calling? (car forms)))
	     (let ((defn (car forms))
		   (others (append (reverse done) (cdr forms))))
	       ;; Can insert other inlining restrictions here
	       (loop (inline-defn defn others))))
	    (else (scan (cons (car forms) done) (cdr forms)))))))

;;;; Term-rewriting tidier

(define tidy
  (rule-simplifier
   (list
    (rule `(let () (? body)) body)
    (rule `(begin (? body)) body)
    (rule `(car (cons (? a) (? d))) a)
    (rule `(cdr (cons (? a) (? d))) d)
    (rule `(vector-ref (vector (?? stuff)) (? index ,integer?))
	  (list-ref stuff index))
    (rule `(let (((? name ,symbol?) (? exp))) (? name)) exp)

    (rule `((lambda (? names) (?? body)) (?? args))
	  `(let ,(map list names args) ,@body))

    (rule `(let ((?? bindings1)
		 ((? name ,symbol?) (? exp))
		 (?? bindings2))
	     (?? body))
	  (let ((occurrence-count (count-free-occurrences name body)))
	    (and (or (= 0 occurrence-count)
		     (and (not (memq exp (append (map car bindings1)
						 (map car bindings2))))
			  (or (= 1 occurrence-count)
			      (constructors-only? exp))))
		 `(let (,@bindings1
			,@bindings2)
		    ,@(replace-free-occurrences name exp body))))))))
