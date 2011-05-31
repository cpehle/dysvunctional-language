(declare (usual-integrations))
;;;; Forward Mode AD

;;; For an explanation of what automatic differentiation is and why
;;; you want it, including what forward-mode is an how it differs from
;;; reverse-mode, see TODO.  Here I will just explain how it is done
;;; in SLAD.

;;; The goal of forward mode is to compute the directional derivative
;;; of a given primal function f at a given primal point x in a given
;;; tangent direction x'.  The essence of forward mode is to augment
;;; the primal computation to operate on truncated Taylor series in a
;;; formal parameter eps <> 0, but with eps^2 = 0.  Then, if you call
;;; this augmented computation on x + eps x', the result y + eps y'
;;; will contain both the primal answer y and the desired directional
;;; derivative y'.

;;; The central element of this entire operation in SLAD is the
;;; procedure TRANSFORM-AND-PERTURB.  It accepts a primal object and a
;;; perturbation to that object (which is assumed EQUAL? except for
;;; any real numbers it may contain), and returns the corresponding
;;; forward-mode object.  In the case of real numbers, it produces
;;; bundles (which are the direct representation of the truncated
;;; Taylor series).  In the case of procedures, it accomplishes the
;;; transformation necessary to cause those procedures to accept
;;; bundles as arguments, and also brings in any supplied perturbation
;;; to (the constants and closed-over variables in) the procedure.

;;; SLAD maintains the following structure invariant: bundles are
;;; always interleaved as deep down into non-bundle structures as
;;; possible.  In other words, a bundle will never contain anything
;;; except bundles and real numbers; and when you
;;; TRANSFORM-AND-PERTURB some object, you will get an EQUAL? object,
;;; except that the real numbers or bundles at the leaves will have
;;; been replaced with new bundles that carry the perturbation
;;; information, and procedures in the object will have been changed
;;; to accept and emit bundles.

;;; Nested bundles also have to kept straight, to avoid perturbation
;;; confusion.  The SLAD invariant on nested bundles is the outermost
;;; bundle corresponds to the dynamically nearest call to derviative
;;; (and company).  In other words, in
;;;   (derviative_1 (derviative_2 (lambda (x) ... x ...)))
;;; the reference to x will see
;;;   (bundle_2 (bundle_1 foo bar) (bundle_1 baz quux)).

;;; Complementary to TRANSFORM-AND-PERTURB are three other
;;; bundle-manipulation procedures: PRIMAL, TANGENT, and
;;; ZERO.  The first two extract their respective components of
;;; bundles (untransforming procedures along the way), and the third
;;; constructs the zero of the perturbation space of its argument.

(define (transform-and-perturb object perturbation)
  ;; Assume without checking that the perturbation is an object of
  ;; exactly the same type and shape as the original object.
  (cond ((forward-transform-known? object)
         ((get-forward-transform object) perturbation))
        ((primitive? object)
         (error "Cannot transform primitives whose transforms are not known"
                object perturbation))
        ((real? object)
         (make-bundle object perturbation))
        ((bundle? object)
         ;; This interleaves new perturbations into existing bundles.
         ;; The alternative would have been to just cons them on, with
         (make-bundle object perturbation)
         ;; TODO Which way? Cons or interleave? This has to agree with
         ;; the access pattern to avoid perturbation confusion.
         #;(make-bundle
          (transform-and-perturb (primal object)
                                 (primal perturbation))
          (transform-and-perturb (tangent object)
                                 (tangent perturbation))))
        ;; Notably, forward mode relegates to object-map for
        ;; closure objects.  This is because it does not acutally
        ;; need to make any changes to the closure bodies, except
        ;; maybe to avoid confusing perturbations.
        ((or (closure? object) (env? object) (pair? object))
         (congruent-map transform-and-perturb object perturbation
          (lambda ()
            (error "Object and perturbation are not congruent"))))
        (else ; trivial tangent space, TODO check congruence
         object)))

(define (primal thing)
  (cond ((bundle? thing)
         (bundle-primal thing))
        ((primal-cached? thing)
         (cached-primal thing))
        ((real? thing)
         (error "Cannot take the primal of a non-bundle" thing))
        (else
         (object-map primal thing))))

(define (tangent thing)
  (cond ((bundle? thing)
         (bundle-tangent thing))
        ((tangent-cached? thing)
         (cached-tangent thing))
        ((real? thing)
         (error "Cannot take the tangent of a non-bundle" thing))
        (else
         (object-map tangent thing))))

(define (zero object)
  (cond ((real? object)
         0)
        (else
         (object-map zero object))))
;; TODO Actually cache the transforms of things once they are computed?

(define forward-transforms (make-eq-hash-table))

(define (set-forward-transform! object transform)
  ;; All standard forward transforms ignore the perturbation
  (hash-table/put! forward-transforms object (lambda (perturbation)
                                               transform))
  (hash-table/put! primal-cache transform object)
  (hash-table/put! tangent-cache transform object)
  'forward-transform-assigned)

(define (forward-transform-known? object)
  (let ((unique (list 'unique)))
    (let ((answer (hash-table/get forward-transforms object unique)))
      (not (eq? unique answer)))))

(define (get-forward-transform object)
  (hash-table/get forward-transforms object #f))

;; TODO Change these to use hash-table/lookup so they answer correctly on #f.
(define primal-cache (make-eq-hash-table))
(define (primal-cached? object)
  (hash-table/get primal-cache object #f))
(define (cached-primal object)
  (hash-table/get primal-cache object #f))

(define tangent-cache (make-eq-hash-table))
(define (tangent-cached? object)
  (hash-table/get tangent-cache object #f))
(define (cached-tangent object)
  (hash-table/get tangent-cache object #f))

(set-forward-transform! #t #t)
(set-forward-transform! #f #f)

#|
;;; Thoughts about interleaving.  Here is how Stalingrad transforms
;;; the procedures BUNDLE and PRIMAL, and what the corresponding noops
;;; would look like:

;;; Bundle:
;; Stalingrad:
(lambda (pair-bundles-b)
  (let (((cons primal-a-primal-b  tangent-a-primal-b)  (primal  pair-bundles-b))
        ((cons primal-a-tangent-b tangent-a-tangent-b) (tangent pair-bundles-b)))
    (bundle
     (bundle primal-a-primal-b  tangent-a-primal-b)
     (bundle primal-a-tangent-b tangent-a-tangent-b))))

;; Noop:
(lambda (pair-bundles-b)
  (let (((cons primal-a-primal-b  tangent-a-primal-b)  (primal  pair-bundles-b))
        ((cons primal-a-tangent-b tangent-a-tangent-b) (tangent pair-bundles-b)))
    (bundle
     (bundle primal-a-primal-b  primal-a-tangent-b)
     (bundle tangent-a-primal-b tangent-a-tangent-b))))


;;; Primal:
;; Stalingrad:
(lambda (bundle-a-bundle-b)
  (let ((primal-a-bundle-b (primal bundle-a-bundle-b))
        (tangent-a-bundle-b (tangent bundle-a-bundle-b)))
    (bundle (primal primal-a-bundle-b)
            (primal tangent-a-bundle-b))))

;; Noop:
(lambda (bundle-a-bundle-b)
  (let ((primal-a-bundle-b (primal bundle-a-bundle-b))
        (tangent-a-bundle-b (tangent bundle-a-bundle-b)))
    (bundle (primal  primal-a-bundle-b)
            (tangent primal-a-bundle-b))))


|#