(declare (usual-integrations))

(define (default-extension-to-vlad pathname)
  (merge-pathnames (->pathname pathname) (->pathname "foo.vlad")))

(define (include-directive? form)
  (and (list? form)
       (= (length form) 2)
       (eq? (first form) 'include)
       (string? (second form))))

(define (read-source pathname)
  (let ((pathname (default-extension-to-vlad pathname)))
    (call-with-input-file pathname
      (lambda (input-port)
	(let loop ((forms '()) (ignore? #f))
	  (let ((form (read input-port)))
	    (cond
	     ((eof-object? form) (reverse forms))
	     (ignore? (loop forms #f))
	     ((eq? '===> form) (loop forms #t))
	     ((include-directive? form)
	      (loop
	       (append (reverse (with-working-directory-pathname
				 (directory-namestring pathname)
				 (lambda ()
				   (read-source (second form)))))
		       forms)
	       #f))
	     (else (loop (cons form forms) #f)))))))))
