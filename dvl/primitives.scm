;;; ----------------------------------------------------------------------
;;; Copyright 2010-2011 National University of Ireland.
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
;;;; DVL primitive procedures

;;; A DVL primitive procedure needs to tell the concrete evaluator how
;;; to execute it, the analyzer how to think about calls to it, and
;;; the code generator how to emit calls to it.  These are the
;;; implementation, abstract-implementation and generate slots,
;;; respectively.  Every primitive also has a name, which is also the
;;; symbol in the initial environment in the source language to which
;;; it is bound.

(define-structure
  (primitive
   safe-accessors
   (print-procedure
    (simple-unparser-method 'primitive
     (lambda (object)
       (list (primitive-name object))))))
  name                                  ; source language
  implementation                        ; concrete eval
  abstract-implementation               ; abstract eval
  generate)                             ; code generator

(define *primitives* '())

(define (add-primitive! primitive)
  (set! *primitives* (cons primitive *primitives*)))

(define (simple-primitive name arity implementation abstract-implementation)
  (make-primitive name
   (lambda (arg world win)
     (win (implementation arg) world))
   (lambda (arg world analysis win)
     (win (abstract-implementation arg) world))
   (simple-primitive-application name arity)))

;;; Most primitives fall into a few natural classes:

;;; Unary numeric primitives just have to handle getting abstract
;;; values for arguments (to wit, ABSTRACT-REAL).
(define (unary-primitive name base abstract-answer)
  (simple-primitive name 1
   base
   (lambda (arg)
     (if (some-real? arg)
         (if (abstract-real? arg)
             abstract-answer
             (base arg))
         (dvl-error "Bad argument" name
                    (error-irritant/noise " expects real, given") arg)))))

;;; Binary numeric primitives also have to destructure their input,
;;; because the VL system will hand it in as a pair.
(define (binary-primitive name base abstract-answer)
  (simple-primitive name 2
   (lambda (arg)
     (base (car arg) (cdr arg)))
   (lambda (arg)
     (let ((first (car arg))
           (second (cdr arg)))
       (if (and (some-real? first)
                (some-real? second))
           (if (or (abstract-real? first)
                   (abstract-real? second))
               abstract-answer
               (base first second))
           (dvl-error "Bad argument" name
                      (error-irritant/noise " expects two reals, given")
                      first second))))))

;;; Type predicates need to take care to respect the possible abstract
;;; types.
(define (primitive-type-predicate name base)
  (simple-primitive name 1
   base
   (lambda (arg)
     (cond ((abstract-real? arg)
            (eq? base real?))
           ((abstract-boolean? arg)
            (eq? base boolean?))
           ((abstract-gensym? arg)
            (eq? base gensym?))
           (else
            (base arg))))))

(define-syntax define-R->R-primitive
  (syntax-rules ()
    ((_ name)
     (add-primitive! (unary-primitive 'name name abstract-real)))))

(define-syntax define-R->bool-primitive
  (syntax-rules ()
    ((_ name)
     (add-primitive! (unary-primitive 'name name abstract-boolean)))))

(define-syntax define-RxR->R-primitive
  (syntax-rules ()
    ((_ name)
     (add-primitive! (binary-primitive 'name name abstract-real)))))

(define-syntax define-RxR->bool-primitive
  (syntax-rules ()
    ((_ name)
     (add-primitive! (binary-primitive 'name name abstract-boolean)))))

(define-syntax define-primitive-type-predicate
  (syntax-rules ()
    ((_ name)
     (add-primitive! (primitive-type-predicate 'name name)))))

;;; The usual suspects:

(define-R->R-primitive abs)
(define-R->R-primitive exp)
(define-R->R-primitive log)
(define-R->R-primitive sin)
(define-R->R-primitive cos)
(define-R->R-primitive tan)
(define-R->R-primitive asin)
(define-R->R-primitive acos)
(define-R->R-primitive sqrt)

(define-RxR->R-primitive +)
(define-RxR->R-primitive -)
(define-RxR->R-primitive *)
(define-RxR->R-primitive /)
(define-RxR->R-primitive atan)
(define-RxR->R-primitive expt)

(define-primitive-type-predicate null?)
(define-primitive-type-predicate pair?)
(define-primitive-type-predicate boolean?)
(define-primitive-type-predicate real?)

(define (vl-procedure? thing)
  (or (primitive? thing)
      (closure? thing)))
(add-primitive! (primitive-type-predicate 'procedure? vl-procedure?))

(define-RxR->bool-primitive  <)
(define-RxR->bool-primitive <=)
(define-RxR->bool-primitive  >)
(define-RxR->bool-primitive >=)
(define-RxR->bool-primitive  =)

(define-R->bool-primitive zero?)
(define-R->bool-primitive positive?)
(define-R->bool-primitive negative?)

;;; Side-effects from I/O procedures need to be hidden from the
;;; analysis.

(add-primitive!
 (simple-primitive 'read-real 0
  (lambda (arg) (read-real))
  (lambda (arg) abstract-real)))

(add-primitive!
 (simple-primitive 'write-real 1
  write-real
  (lambda (arg) arg)))

;;; We need a mechanism to introduce imprecision into the analysis.
;;; REAL must take care to always emit an ABSTRACT-REAL during
;;; analysis, even though it's the identity function at runtime.
;;; Without this, "union-free flow analysis" would amount to running
;;; the program very slowly at analysis time until the final answer
;;; was computed.

(add-primitive!
 (simple-primitive 'real 1
  real
  (lambda (x)
    (cond ((abstract-real? x) abstract-real)
          ((number? x) abstract-real)
          (else (dvl-error "A known non-real is declared real" x))))))

;;; IF-PROCEDURE is special because it is the only primitive that
;;; accepts VL closures as arguments and invokes them internally.
;;; That is handled transparently by the concrete evaluator, but
;;; IF-PROCEDURE must be careful to analyze its own return value as
;;; being dependent on the return values of its argument closures, and
;;; let the analysis know which of its closures it will invoke and
;;; with what arguments as the analysis discovers knowledge about
;;; IF-PROCEDURE's predicate argument.  Also, the code generator
;;; detects and special-cases IF-PROCEDURE because it wants to emit
;;; native Scheme IF statements in correspondence with VL IF
;;; statements.

(define (if-procedure p c a)
  (if p (c) (a)))

(define primitive-if
  (make-primitive 'if-procedure
   (lambda (arg world win)
     (if (car arg)
         (concrete-apply (cadr arg) '() world win)
         (concrete-apply (cddr arg) '() world win)))
   (lambda (shape world analysis win)
     (let ((predicate (car shape)))
       (if (not (abstract-boolean? predicate))
           (if predicate
               (abstract-result-in-world (cadr shape) world analysis win)
               (abstract-result-in-world (cddr shape) world analysis win))
           (abstract-result-in-world (cadr shape) world analysis
            (lambda (first-value first-world)
              (abstract-result-in-world (cddr shape) world analysis
               (lambda (second-value second-world)
                 (win (abstract-union first-value second-value)
                      (union-world first-world second-world)))))))))
   generate-if-statement))
(add-primitive! primitive-if)

(define (abstract-result-in-world thunk-shape world analysis win)
  ;; N.B. ABSTRACT-RESULT-IN-WORLD only exists because of the way I'm doing IF.
  (get-during-flow-analysis
   `(,(closure-exp thunk-shape) ())
   (closure-env thunk-shape)
   world
   analysis
   win))

(define (abstract-result-of thunk-shape analysis)
  (analysis-get thunk-shape '() analysis))

;;;; Gensym

(add-primitive!
 (make-primitive 'gensym
  (lambda (arg world win)
    (win (current-gensym world) (do-gensym world)))
  (lambda (arg world analysis win)
    (win (trivial-abstract-gensym
          (current-gensym world))
         (do-gensym world)))
  (simple-primitive-application 'gensym 0)))

(add-primitive!
 (simple-primitive 'gensym= 2
  (lambda (arg)
    (gensym= (car arg) (cdr arg)))
  (lambda (arg)
    (let ((first (car arg))
          (second (cdr arg)))
      (if (and (abstract-gensym? first)
               (abstract-gensym? second))
          (let ((first-low   (abstract-gensym-min first))
                (first-high  (abstract-gensym-max first))
                (second-low  (abstract-gensym-min second))
                (second-high (abstract-gensym-max second)))
            (cond ((= first-low first-high second-low second-high)
                   #t)
                  ((< first-high second-low)
                   #f)
                  ((> first-low second-high)
                   #f)
                  (else
                   abstract-boolean)))
          (dvl-error "Bad argument" 'gensym=
                     (error-irritant/noise " expects two gensyms, given")
                     first second))))))

(define-primitive-type-predicate gensym?)

(add-primitive!
 (simple-primitive 'gensym< 2
  (lambda (arg)
    (gensym< (car arg) (cdr arg)))
  (lambda (arg)
    (let ((first (car arg))
          (second (cdr arg)))
      (if (and (abstract-gensym? first)
               (abstract-gensym? second))
          (let ((first-low   (abstract-gensym-min first))
                (first-high  (abstract-gensym-max first))
                (second-low  (abstract-gensym-min second))
                (second-high (abstract-gensym-max second)))
            (cond ((< first-high second-low)
                   #t)
                  ((>= first-low second-high)
                   #f)
                  (else
                   abstract-boolean)))
          (dvl-error "Bad argument" 'gensym<
                     (error-irritant/noise " expects two gensyms, given")
                     first second))))))

;;;; User detection of errors

(add-primitive!
 (simple-primitive 'error 0
  (lambda (arg)
    (error "DVL user error" arg))
  (lambda (arg)
    ;; TODO Add support for strings as error messages
    (dvl-error "DVL user error" arg))))

(define (initial-user-env)
  (make-env
   (map (lambda (primitive)
          (cons (primitive-name primitive) primitive))
        *primitives*)))
