;;; ----------------------------------------------------------------------
;;; Copyright 2013 Alexey Radul.
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
;;;; Compilation with the fol2hs backend and GHC

(define (fol->haskell program #!optional output-base)
  (if (default-object? output-base)
      (set! output-base "hanozzle"))
  (let* ((module-name (as-haskell-module-name (pathname-name output-base)))
         (directory (->namestring (pathname-new-name output-base #f)))
         (path (->namestring (pathname-new-type (pathname-new-name output-base module-name) #f)))
         (written-program (with-output-to-string (lambda () (pp program)))))
    (force-shell-command (format #f "fol2hs -e value -m ~A --directory=~A" module-name directory)
                         'input (open-input-string written-program))
    (let* ((file (->namestring (pathname-new-type path "hs")))
           (cmd (format #f "ghc ~A -main-is ~A.main -outputdir ~A -o ~A"
                        file module-name directory path)))
      (force-shell-command cmd))))

(define (as-haskell-module-name string)
  ;; TODO Increase the accuracy of this model
  (string-set! string 0 (char-upcase (string-ref string 0)))
  string)

(define (run-haskell #!optional output-base)
  (if (default-object? output-base)
      (set! output-base "hanozzle"))
  (let* ((module-name (as-haskell-module-name (pathname-name output-base)))
         (path (->namestring (pathname-new-type (pathname-new-name output-base module-name) #f))))
   (force-shell-command path)))
