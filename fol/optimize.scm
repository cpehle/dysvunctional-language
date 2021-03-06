;;; ----------------------------------------------------------------------
;;; Copyright 2010-2011 National University of Ireland; 2013 Alexey Radul.
;;; ----------------------------------------------------------------------
;;; This file is part of DysVunctional Language.
;;; 
;;; DysVunctional Language is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU Affero General Public License as
;;; published by the Free Software Foundation, either version 3 of the
;;;  License, or (at your option) any later version.
;;; 
;;; DysVunctional Language is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;; 
;;; You should have received a copy of the GNU Affero General Public License
;;; along with DysVunctional Language.  If not, see <http://www.gnu.org/licenses/>.
;;; ----------------------------------------------------------------------

(declare (usual-integrations))
;;;; Optimization toplevel

;;; The FOL optimizer consists of several stages:
;;; - INLINE
;;;   Inline non-recursive function definitions.
;;; - INTRAPROCEDURAL-CSE
;;;   Eliminate common subexpressions (including redundant variables that
;;;   are just aliases of other variables or constants).
;;;   Perform some algebraic simplification during CSE.
;;; - ELIMINATE-INTRAPROCEDURAL-DEAD-CODE
;;;   Eliminate dead code.
;;; - SCALAR-REPLACE-AGGREGATES
;;;   Replace aggregates with scalars.
;;; - ELIMINATE-INTERPROCEDURAL-DEAD-CODE
;;;   Eliminate dead code across procedure boundaries.
;;; - REVERSE-ANF
;;;   Inline bindings of variables that are only used once, to make the
;;;   output easier to read.

;;; The FOL optimizer also uses several supporting procedures to massage
;;; the program's form for the convenience of the main stages:
;;; - STRUCTURE-DEFINITIONS->VECTORS
;;;   Replace named records and accessors with vectors and vector-refs.
;;; - CHECK-FOL-TYPES
;;;   Syntax check, type check, and compute the type of the entry point.
;;; - ALPHA-RENAME
;;;   Uniquify local variable names.
;;; - APPROXIMATE-ANF
;;;   Name all intermediate values.
;;; - LIFT-LETS
;;;   Increase variable scopes.

;;; See doc/architecture.txt for discussion.

;;; Using the stage machinery, the fol optimizer looks like this

;; The properties are
;; structures-as-vectors
;; syntax-checked
;; type
;; unique-names
;; a-normal-form
;; lets-lifted
;; fully-inlined  (for testing only)
;; aggregates-replaced (for testing only)
;; no-common-subexpressions (for testing only)
;; no-intraprocedural-dead-variables (for testing only)
;; no-interprocedural-dead-variables (for testing only)
;; no-lambda-type-declarations (transitional while not all stages can deal with them)

;; The possible clause types are
;; preserves generates destroys
;; requires
;; computes reads
;; name

;;; TODO Use software validation techniques to prove that these stages
;;; conserve or destroy the properties they say they converse or
;;; destroy?

;;; Form normalizers

(define-stage structure-definitions->vectors
  %structure-definitions->vectors
  (preserves type) ; Because closures are never exported anyway
  ;; Because different closure types may collapse
  (destroys no-common-subexpressions)
  ;; Because SRA (currently) operates only on vectors and conses
  (destroys aggregates-replaced)
  (generates structures-as-vectors)
  ;; Actually also generates dead-types-eliminated, but I don't want the
  ;; stage system looking here for that.
  )

(define-stage remove-lambda-type-declarations
  %remove-lambda-type-declarations
  (generates no-lambda-type-declarations))

(define-stage check-fol-types
  check-program-types
  (computes type)
  (generates syntax-checked))

(define-stage alpha-rename
  %alpha-rename
  (generates unique-names)
  (requires syntax-checked))

(define-stage a-normal-form
  approximate-anf
  (generates a-normal-form)
  (destroys lets-lifted) ; Because of multiple argument procedures
  ;; By naming new things that may be common
  (destroys no-common-subexpressions)
  (requires syntax-checked))

(define-stage lift-lets
  %lift-lets
  (generates lets-lifted)
  ;; TODO Does it really preserve a-normal-form ?
  (requires syntax-checked unique-names)
  (requires a-normal-form)   ; Just because I'm lazy
  ;; By splitting lets
  (destroys no-common-subexpressions))

;;; Main stages

(define-stage inline
  %inline
  ;; Because of multiple procedure arguments
  (destroys lets-lifted)
  ;; Because of copying procedure bodies
  (destroys unique-names no-common-subexpressions)
  ;; By removing procedure definitions (only comes into play if a
  ;; procedure declared an argument of some otherwise-dead type but
  ;; didn't use it).
  (destroys dead-types-eliminated)
  ;; Because of removing procedure boundaries
  (destroys no-intraprocedural-dead-variables)
  ;; Because of specializing to different places
  (destroys no-interprocedural-dead-variables)
  (requires syntax-checked)
  (generates fully-inlined))                  ; not really, but on current examples

(define (sra-may-destroy property)
  (modify-execution-function
   (lambda (exec)
     (lambda (program)
       (let ((val (property-value property program))
             (answer (exec program)))
         (if (memq (property-value 'type program) '(bool real))
             (property-value! property val answer)
             (property-value! property #f answer))
         answer)))))

(define-stage scalar-replace-aggregates
  %scalar-replace-aggregates
  ;; TODO Does it require unique-names?  It may, if it deparallelizes
  ;; let-values (in its post-processor).
  (requires syntax-checked a-normal-form)
  (generates aggregates-replaced)
  ;; Because of the reconstruction
  (sra-may-destroy aggregates-replaced)
  ;; Because of reconstruction and let-values simplification (?)
  (destroys lets-lifted)
  ;; By removing uses of structure types
  (destroys dead-types-eliminated)
  ;; By making aliases, and exposing structure slots to CSE
  (destroys no-common-subexpressions)
  ;; By exposing structure slots as variables
  (destroys no-intraprocedural-dead-variables
            no-interprocedural-dead-variables))

(define-stage eliminate-dead-types
  %dead-type-elimination
  (requires syntax-checked)
  (generates dead-types-eliminated))

(define-stage intraprocedural-cse
  %intraprocedural-cse
  ;; These two requirements are not really requirements, but it works
  ;; much better this way.
  (requires a-normal-form lets-lifted)
  (requires unique-names) ; Because it does some internal let-lifting
  (requires syntax-checked)
  (generates no-common-subexpressions)
  ;; By leaving some dead aliases around
  (destroys no-intraprocedural-dead-variables
            no-interprocedural-dead-variables))

(define-stage eliminate-intraprocedural-dead-code
  %eliminate-intraprocedural-dead-code
  ;; Does not preserve fully-inlined in general because may alter the
  ;; call graph, but on all current examples it does.
  ;; When there are union types, it may destroy aggregates-replaced
  ;; for the same reason.
  (generates no-intraprocedural-dead-variables)
  ;; TODO Does it really require unique names?
  (requires syntax-checked unique-names)
  ;; Because of inserting let-values around procedure calls
  (destroys lets-lifted)
  ;; By removing expressions
  (destroys dead-types-eliminated)
  )

(define-stage eliminate-interprocedural-dead-code
  ;; TODO Do I want to split this into the pure-interprocedural part
  ;; and the intraprocedural part?  One problem: the former
  ;; technically does not preserve type correctness, because it
  ;; inserts tombstones which currently do not type properly.  In
  ;; fact, this criticism can be levelled against the composition
  ;; as well, in general.
  interprocedural-dead-code-elimination
  ;; TODO Does it really require unique names?
  (requires syntax-checked unique-names)
  (generates no-interprocedural-dead-variables)
  ;; By running intraprocedural as a post-pass
  (generates no-intraprocedural-dead-variables)
  ;; Because of inserting let-values around procedure calls
  (destroys lets-lifted)
  ;; By removing expressions
  (destroys dead-types-eliminated)
  )

(define-stage reverse-anf
  %reverse-anf
  ;; TODO Does it really preserve lets-lifted?
  (destroys a-normal-form)
  (requires syntax-checked unique-names))

;;; I am mildly apologetic about this mildly unfortunate procedure.
;;; The problem is that algebraic simplifications that trigger on
;;; nested expressions are too complicated to add to the current
;;; architecture of the common subexpression eliminator (see comments
;;; around simplify-access in cse.scm).  Some instances, however,
;;; become apparent after reverse-anf.  So this is here to
;;; opportunistically pick up the ones that do.  In particular, the
;;; Mandelbrot example gets a 20% speedup from this.  The reason this
;;; arrangement is less than ideal is that doing it this way misses
;;; ones that non-uniqueness of use leaves obscured, and also misses
;;; any cascades with further CSE.
(define %peephole-optimize
  (term-rewriting ; n.b. constants migrated to front by cse
   ;; appears in celestial.dvl
   (rule '(* -1 (* -1 x)) x)
   ;; appears in celestial.dvl and mandel.dvl
   (rule '(+ (? x) (* -1 (? y)))
         `(- ,x ,y))
   ;; TODO (/ (* x stuff) (* x other stuff)) should appear in
   ;; celestial.dvl but may be obscured
   ))

(define-stage peephole-optimize
  %peephole-optimize
  (destroys no-common-subexpressions))

;;; Standard ordering

(define fol-optimize
  (stage-pipeline
   peephole-optimize
   reverse-anf
   eliminate-dead-types
   eliminate-interprocedural-dead-code
;   eliminate-intraprocedural-dead-code ; This is slow and mostly redundant
   intraprocedural-cse
   scalar-replace-aggregates
   eliminate-intraprocedural-dead-code
   intraprocedural-cse
   inline))

(define loopy-fol-optimize
  (stage-pipeline
   peephole-optimize
   reverse-anf
   (loop-while-shrinks
    (stage-pipeline
     eliminate-dead-types
     eliminate-interprocedural-dead-code
     intraprocedural-cse
     scalar-replace-aggregates
     (loop-while-shrinks
      (stage-pipeline
       eliminate-intraprocedural-dead-code
       intraprocedural-cse
       inline))))))

;;; Adverbs

(define (watching-annotations stage-data)
  (lambda (exec)
    (lambda (program . extra)
      (display "(")
      (pp (stage-data-name stage-data))
      (abegin1
       (apply exec program extra)
       (pp (hash-table/get eq-properties it #f))
       (display ")")))))

(define (report-stage-progress stage name show-program)
  (lambda (program . extra)
    (format #t "Stage ~A on " name)
    (show-program program)
    (abegin1 (show-time (lambda () (apply stage program extra)))
      (newline)
      (when (eq? name 'reverse-anf)
        (display "Final output has ")
        (show-program it)))))

(define (visibly stage-data)
  (lambda (exec)
    (report-stage-progress exec (stage-data-name stage-data)
     (lambda (program)
       (if (eq? (stage-data-name stage-data) 'generate)
           ;; The generate stage wants to display different stats
           (format #t "~A bindings\n"
                   (length
                    ((access analysis-bindings (nearest-repl/environment))
                     (property-value 'analysis program))))
           (print-fol-size program))))))

(define (volubly stage-data)
  (lambda (exec)
    (report-stage-progress exec (stage-data-name stage-data)
     (lambda (program)
       (if (eq? (stage-data-name stage-data) 'generate)
           ;; The generate stage wants to display different stats
           (format #t "~A bindings\n"
                   (length
                    ((access analysis-bindings (nearest-repl/environment))
                     (property-value 'analysis program))))
           (print-fol-statistics program))))))

(define (dumping-intermediate stage-data)
  (lambda (exec)
    (report-stage-progress exec (stage-data-name stage-data)
     (lambda (program)
       (newline)
       (pp program)))))

(define (measuring-memory stage-data)
  (lambda (exec)
    (lambda (program . extra)
      (if (eq? (stage-data-name stage-data) 'generate)
          (format #t "analysis of size ~A\n"
                  (estimate-space-usage (property-value 'analysis program)))
          (format #t "program of size ~A\n" (estimate-space-usage program)))
      (format #t "~A free words\n" (gc-flip))
      (print-gc-statistics)
      (apply exec program extra))))

(define (watching-memory stage-data)
  (lambda (exec)
    (lambda (program . extra)
      (format #t "~A free words\n" (gc-flip))
      (print-gc-statistics)
      (apply exec program extra))))

(define (type-safely stage-data)
  (lambda (exec)
    (lambda (program . extra)
      (abegin1 (apply exec program extra)
        (if (present? 'syntax-checked it)
            (check-program-types it))))))
