(declare (usual-integrations))
;;;; Syntax and manipulations of the output language

(define let-form? (tagged-list? 'let))
(define if-form? (tagged-list? 'if))

(define ->lambda
  (rule `(let (? bindings) (?? body))
        `((lambda ,(map car bindings)
            ,@body)
          ,@(map cadr bindings))))

(define ->let
  (rule `((lambda (? names) (?? body)) (?? args))
        `(let ,(map list names args) ,@body)))

(define reconstitute-definition
  (iterated
   (rule `(define (? name)
            (lambda (? names)
              (?? body)))
         `(define (,name ,@names)
            ,@body))))

(define remove-defn-argument-types
  (rule `(define (? formals)
           (argument-types (?? etc))
           (?? body))
        `(define ,formals
           ,@body)))

(define strip-argument-types
  (rule-simplifier (list remove-defn-argument-types)))

(define values-form? (tagged-list? 'values))
(define let-values-form? (tagged-list? 'let-values))

(define (constructors-only? exp)
  (or (symbol? exp)
      (constant? exp)
      (null? exp)
      (and (pair? exp)
           (memq (car exp) '(cons vector real car cdr vector-ref))
           (every constructors-only? (cdr exp)))))

(define (occurs-in-tree? thing tree)
  (cond ((equal? thing tree) #t)
        ((pair? tree)
         (or (occurs-in-tree? thing (car tree))
             (occurs-in-tree? thing (cdr tree))))
        (else #f)))

(define (filter-map-tree proc tree)
  (let walk ((tree tree) (answer '()))
    (if (pair? tree)
        (walk (car tree) (walk (cdr tree) answer))
        (let ((elt (proc tree)))
          (if elt
              (cons elt answer)
              answer)))))

(define (count-free-occurrences name exp)
  (cond ((eq? exp name) 1)
        ((lambda-form? exp)
         (if (occurs-in-tree? name (lambda-formal exp))
             0
             (count-free-occurrences name (cddr exp))))
        ((let-form? exp)
         (count-free-occurrences name (->lambda exp)))
        ((pair-form? exp)
         (+ (count-free-occurrences name (car-subform exp))
            (count-free-occurrences name (cdr-subform exp))))
        ((pair? exp)
         (+ (count-free-occurrences name (car exp))
            (count-free-occurrences name (cdr exp))))
        (else 0)))

(define (replace-free-occurrences name new exp)
  (cond ((eq? exp name) new)
        ((lambda-form? exp)
         (if (occurs-in-tree? name (lambda-formal exp))
             exp
             `(lambda ,(lambda-formal exp)
                ,@(replace-free-occurrences name new (cddr exp)))))
        ((let-form? exp)
         (->let (replace-free-occurrences name new (->lambda exp))))
        ((pair-form? exp)
         `(cons ,(replace-free-occurrences name new (car-subform exp))
                ,(replace-free-occurrences name new (cdr-subform exp))))
        ((pair? exp)
         (cons (replace-free-occurrences name new (car exp))
               (replace-free-occurrences name new (cdr exp))))
        (else exp)))

;;;; "Runtime system"

(define (fol-eval code)
  (eval code (nearest-repl/environment)))

(define-syntax argument-types
  (syntax-rules ()
    ((_ arg ...)
     (begin))))
