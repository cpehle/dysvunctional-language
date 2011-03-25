(declare (usual-integrations))
;;;; (Approximate) A-normal form conversion

;;; In order to do a good job of scalar replacement of aggregates, the
;;; program being replaced needs to have names for all interesting
;;; intermediate values (so that those names can serve as a place to
;;; hang information about their pre-sra types and their post-sra
;;; replacement names).  A-normal form was designed to serve exactly
;;; this purpose; but I don't need a full A-normal form to achieve my
;;; aim.  To that end, this program converts a FOL program into
;;; "approximate" A-normal form.

;;; Approximate A-normal form requires that all procedure applications
;;; and all mutlivalue returns apply to (resp. return) variables or
;;; constants, rather than the results of any compound computations.
;;; This differs from full A-normal form in that, for example, the
;;; subexpressions of IF do not have to be variables, and parallel LET
;;; is still allowed.

;;; The precise grammar of FOL in approximate ANF is the same as the
;;; normal FOL grammar, except for replacing the <expression>
;;; nonterminal with the following:
;;;
;;; simple-expression = <data-var> | <number> | <boolean> | ()
;;;
;;; expression = <simple-expression>
;;;            | (if <expression> <expression> <expression>)
;;;            | (let ((<data-var> <expression>) ...) <expression>)
;;;            | (let-values (((<data-var> <data-var> <data-var> ...) <expression>))
;;;                <expression>)
;;;            | (values <simple-expression> <simple-expression> <simple-expression> ...)
;;;            | (<proc-var> <simple-expression> ...)

;;; The following program converts an arbitrary FOL expression into
;;; approximate ANF.  The way to do this is to recur down the
;;; structure of the FOL expression and, should a general <expression>
;;; ever be found in any place where there should only be a
;;; <simple-expression>, introduce a fresh variable binding to hold
;;; the result of that <expression> and put this variable in that
;;; place.  Such a variable will never need to capture a multivalue
;;; return, because the places where <simple-expression>s are needed
;;; only accept single values by the rules of FOL anyway.

(define (push-access expr1 expr2)
  `(,(car expr1) ,expr2 ,@(cddr expr1)))

(define (sra-anf expr)
  (define (rename-nontrivial-expression expr win)
    (if (simple-form? expr)
        (win expr '())
        (let ((name (make-name 'anf)))
          (win name `((,name ,expr))))))
  (define (rename-nontrivial-expressions exprs win)
    (if (null? exprs)
        (win '() '())
        (rename-nontrivial-expression
         (car exprs)
         (lambda (result names)
           (rename-nontrivial-expressions (cdr exprs)
            (lambda (results more-names)
              (win (cons result results)
                   (append names more-names))))))))
  (let loop ((expr expr))
    (cond ((simple-form? expr) expr)
          ((if-form? expr)
           `(if ,(loop (cadr expr))
                ,(loop (caddr expr))
                ,(loop (cadddr expr))))
          ((let-form? expr)
           `(let ,(map (lambda (binding)
                         `(,(car binding) ,(loop (cadr binding))))
                       (cadr expr))
              ,(loop (caddr expr))))
          ((let-values-form? expr)
           ((rule `(let-values (((? names) (? exp)))
                     (? body))
                  `(let-values ((,names ,(loop exp)))
                     ,(loop body)))
            expr))
          ((begin-form? expr)
           (map loop expr))
          ((definition? expr)
           ((rule `(define (? formals)
                     (argument-types (?? stuff))
                     (? body))
                  `(define ,formals
                     (argument-types ,@stuff)
                     ,(loop body)))
            expr))
          (else ; application or multiple value return
           (rename-nontrivial-expressions
            expr
            (lambda (results names)
              (if (not (null? names))
                  (loop `(let ,names ,results))
                  expr)))))))

;;; An access chain like
;;; (car (cdr (car ...)))
;;; or a construction chain like
;;; (cons (vector (cons ... ...) ...) ...)
;;; needs to become, after SRA, a single transfer through a multiple
;;; value bind and multiple value return.  Introducing intermediate
;;; names at the ANF stage for all the intermediate values in such a
;;; chain has the effect that SRA will turn that chain into a sequence
;;; of multiple value binds and returns, and leave it to alias
;;; elimination to collapse the sequence into one.  In principle, one
;;; could write a cleverer ANF transformer that goes to a looser
;;; approximation of ANF that allows access and construction sequences
;;; without naming the intermediates; and a cleverer SRA that will
;;; transform such sequences directly into one multiple value bind and
;;; return; and thereby avoid creating extra work for the alias
;;; eliminator.  I have not chosen to do so; partially because the
;;; alias eliminator would be needed anyway.
