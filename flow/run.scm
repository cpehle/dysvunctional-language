(define (start-flow)
  (initialize-flow-user-env)
  (run-flow))

(define (run-flow)
  (display "flow > ")
  (let ((answer (concrete-eval (macroexpand (read)) flow-user-env)))
    (display "; flow value: ")
    (write answer)
    (newline))
  (run-flow))

(define (flow-eval form)
  (initialize-flow-user-env)
  (concrete-eval (macroexpand form) flow-user-env))