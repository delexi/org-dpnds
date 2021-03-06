;;; org-dpnds.el --- Express dependencies between arbitrary headlines.

;; Copyright (C) 2016 Alexander Baier

;; Author: Alexander Baier <alexander.baier@mailbox.org>
;; Homepage: https://github.com/delexi/org-dpnds

;; Version: 0.0.1

;; This file is not part of GNU Emacs.

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

;; -*- lexical-binding: t -*-

(require 'cl-lib)
(require 'dash)
(require 'dash-functional)
(require 'org)
(require 'org-id)
(require 's)

(defconst org-dpnds-property "DEPEND")
(defconst org-dpnds-symbol (intern (concat ":" org-dpnds-property)))

(defun org-dpnds--db-init ()
  (cons (cons (make-hash-table :test 'equal)
              (make-hash-table :test 'equal))
        (make-hash-table :test 'equal)))

(defvar org-dpnds-db (org-dpnds--db-init)
  "The database storing the dependency and scanning information.

This is a cons cell of the following form:

  \(DEPS . SCANS)

DEPS is a hash-table whose keys are ids and whose values are cons
cells of the following form:

  \(DEPENDENCIES . DEPENDERS)

DEPENDENCIES is the list of ids which the key depends on.
DEPENDERS is the list of ids that depend on the key.

SCANS is another hash-table whose keys are filenames and whose
values are the timestamps denoting when those filenames where
last scanned for dependency information.")

(defvar org-dpnds-files org-refile-targets
  "Files scanned for dependant headlines in the format of
  `org-refile-targets'.")

;;; inner helper functions
(defun org-dpnds--db-put (id deps db)
  (let* ((dependencies-db (caar db))
         (dependers-db (cdar db)))
    ;; Do just a put, as these are all the dependencies we are gonna get. Each
    ;; headline stores all its dependencies, so we know, there won't be further
    ;; dependencies.
    (puthash id deps dependencies-db)
    ;; For the dependers we have to add to potentially already existing
    ;; dependers, as this info is only implicit in the org files.
    (mapc
     (lambda (dep)
       (let ((dependers (gethash dep dependers-db)))
         (puthash dep (cons id dependers) dependers-db)))
     deps)))

(defun org-dpnds--get-update-time (file db) (gethash file (cdr db)))
(defun org-dpnds--put-update-time (time file db) (puthash file time (cdr db)))

(defun org-dpnds--get-depend-files ()
  (or
   (-flatten
    (-map
     (-lambda ((fn-or-list . _))
       (cond
        ((listp fn-or-list) fn-or-list)
        ((functionp fn-or-list) (let ((file (funcall fn-or-list)))
                                  (if (listp file) file (list file))))
        (t (error "Car of each cons in `org-dpnds-files' must be a function or a list"))))
     org-dpnds-files))
   (list (buffer-file-name))))

(defun org-dpnds--get-dependencies (pom &optional buffer)
  (cl-assert (integer-or-marker-p pom))
  (cl-assert (bufferp buffer))
  (let* ((pos (if (markerp pom) (marker-position pom) pom))
         (buf (if (markerp pom) (marker-buffer pom) buffer)))
    (with-current-buffer buf
      (org-element-at-point)
      (org-entry-get-multivalued-property pos org-dpnds-property))))

(defun org-dpnds--add-dependency (dep-id pom &optional buffer)
  (cl-assert (stringp dep-id))
  (cl-assert (integer-or-marker-p pom))
  (unless (markerp pom) (cl-assert (bufferp buffer)))
  (let* ((pos (if (markerp pom) (marker-position pom) pom))
         (buf (if (markerp pom) (marker-buffer pom) buffer)))
    (with-current-buffer buf
      (org-element-at-point)
      (org-entry-add-to-multivalued-property pos org-dpnds-property dep-id))))

(defun org-dpnds--remove-dependency (dep-id pom &optional buffer)
  (cl-assert (stringp dep-id))
  (cl-assert (integer-or-marker-p dep-id))
  (unless (markerp pom) (cl-assert (bufferp buffer)))
  (let* ((pos (if (markerp pom) (marker-position pom) pom))
         (buf (if (markerp pom) (marker-buffer pom) buffer)))
    (with-current-buffer buf
      (org-element-at-point)
      (org-entry-remove-from-multivalued-property pos org-dpnds-property dep-id))))

(defun org-dpnds--pomoi-to-id (pomoi &optional create)
  (pcase pomoi
    ((pred integer-or-marker-p) (org-id-get pomoi create))
    ((pred stringp)             pomoi)
    (`nil                       (org-id-get (point) create))
    (_                          nil)))

(defun org-dpnds--pomoi-to-id-check (param pomoi &optional create)
  (-if-let (id (org-dpnds--pomoi-to-id pomoi create))
      id
    (error (concat param " must be an integer, marker, string or nil"))))

(defun org-dpnds--get-id-with-outline-path-completion (&optional targets)
  "Use `outline-path-completion' to retrieve the ID of an entry.
TARGETS may be a setting for `org-refile-targets' to define
eligible headlines.  When omitted, all headlines in the current
file are eligible.  This function returns the ID of the entry.
If necessary, the ID is created."
  (let* ((org-refile-targets (or targets '((nil . (:maxlevel . 10)))))
         (org-refile-use-outline-path nil)
         (org-refile-target-verify-function nil)
         (spos (org-refile-get-location "Entry" nil nil 'no-excludes))
         (pom (and spos (move-marker (make-marker) (nth 3 spos)
                                     (get-file-buffer (nth 1 spos))))))
    (prog1 (org-id-get pom 'create)
      (move-marker pom nil))))

;;; Dependency API
(defun org-dpnds-find (f h db)
  (let ((res (funcall f h)))
    (if res
        res
      (-when-let (dependencies (org-dpnds-get-dependencies h db))
        (-some (lambda (h) (org-dpnds-find f h db)) dependencies)))))

(defun org-dpnds-compare (id1 id2 db)
  (let ((h1<h2 (org-dpnds-find (-partial #'equal id1) id2 db))
        (h1>h2 (org-dpnds-find (-partial #'equal id2) id1 db)))
    (cond
     ((eq h1<h2 h1>h2) 'equal)
     (h1>h2 'smaller)
     (h1<h2 'greater))))

(defun org-dpnds--get (key table &optional transitive)
  "Retrieve all children of KEY from TABLE.

TABLE is a hash-table where each key is mapped to a list of
values.

If TRANSITIVE is non-nil, this function gets the values of KEY
and then looks up all values those values map to and so on. The
combined list of all of these values is returned."
  (-when-let (values (gethash key table))
    (if transitive
        (append values
                (-flatten
                 (-map (-rpartial #'org-dpnds--get table)
                       values)))
      values)))

(defun org-dpnds-get-dependencies (id db &optional transitive)
  (org-dpnds--get id (caar db) transitive))

(defun org-dpnds-get-dependers (id db &optional transitive)
  (org-dpnds--get id (cadr db) transitive))

(defun org-dpnds-sorting-strategy (a b)
  (let* ((ma (or (get-text-property 0 'org-marker a)
                 (get-text-property 0 'org-hd-marker a)))
         (mb (or (get-text-property 0 'org-marker b)
                 (get-text-property 0 'org-hd-marker b)))
         (id-a (org-id-get ma 'create))
         (id-b (org-id-get mb 'create)))
    (cl-case (org-dpnds-compare id-a id-b org-dpnds-db)
      ('equal nil)
      ('greater 1)
      ('smaller -1))))

;;; DB update functionality
(defun org-dpnds-update-db (file db)
  (with-current-buffer (find-file-noselect file)
    (org-map-entries
     (lambda ()
       (let* ((id (org-id-get (point)))
              (dependencies
               (and id
                    (org-dpnds--get-dependencies (point) (current-buffer)))))
         (when dependencies
           (org-dpnds--db-put id dependencies db)
           (org-dpnds--put-update-time (current-time) file db))))
     t 'file))
  db)

(defun org-dpnds-update-db-from-files (files db &optional force)
  (-map (lambda (file)
          (let ((last-update-time (or (org-dpnds--get-update-time file db)
                                      0))
                (mod-time (nth 5 (file-attributes file))))
            (when (or force
                      (time-less-p last-update-time mod-time))
              (org-dpnds-update-db file db))))
        files)
  db)

(defun org-dpnds-update-all-files (&optional force)
  (interactive "P")
  (let ((all-files (org-dpnds--get-depend-files)))
    (when (member (buffer-file-name) all-files)
      (org-dpnds-update-db-from-files all-files org-dpnds-db force))))

(defun org-dpnds-setup ()
  (add-hook 'after-save-hook #'org-dpnds-update-all-files))


;;; Capture onshot hook implementation
(defvar org-dpnds--capture-oneshot-functions nil
  "List of functions run by `org-dpnds--capture-hook-function'.")

(defconst org-dpnds--oneshot-hook-variable 'org-capture-prepare-finalize-hook)

(defun org-dpnds--capture-hook-function ()
  "Runs all functions in `org-dpnds--capture-oneshot-functions' and
then removes itself from `org-dpnds--oneshot-hook-variable'"
  (-map #'funcall org-dpnds--capture-oneshot-functions)
  (setq org-dpnds--capture-oneshot-functions nil)
  (remove-hook org-dpnds--oneshot-hook-variable #'org-dpnds--capture-hook-function))

(defun org-dpnds--capture-add-oneshot-hook (&rest fns)
  (setq org-dpnds--capture-oneshot-functions fns)
  (add-hook org-dpnds--oneshot-hook-variable #'org-dpnds--capture-hook-function))

;;; Graph functions
(defun org-dpnds--merge-graphs (graphs)
  (-reduce-from
   (-lambda ((vs1 . es1) (vs2 . es2))
             (cons (-union vs1 vs2) (-union es1 es2)))
   '(() . ())
   graphs))

(defun org-dpnds-graph (id db)
  (-if-let (deps (org-dpnds-get-dependencies id db))
      (let ((edges (-map (-partial #'cons id) deps))
            (results (org-dpnds--merge-graphs
                      (-map (-rpartial #'org-dpnds-graph db) deps))))
        (cons (cons id (car results)) (append edges (cdr results))))
    (cons (list id) '())))

(defun org-dpnds-graphs (ids db)
  (org-dpnds--merge-graphs
   (-map (-rpartial #'org-dpnds-graph db) ids)))

(defun org-dpnds-get-headline-from-id (id)
  (with-current-buffer (find-file-noselect (car (org-id-find id)))
    (goto-char (cdr (org-id-find id)))
    (plist-get (cadr (org-element-at-point)) :title)))

(defun org-dpnds-graph-to-dot (graph)
  (let* ((edges (-map (-lambda ((from . to))
                        (cons (org-dpnds-get-headline-from-id from)
                              (org-dpnds-get-headline-from-id to)))
                      (cdr graph)))
         (edges-dot (-map (-lambda ((from . to))
                            (format "\"%s\" -> \"%s\";" from to))
                          edges)))
    (s-join "\n"
            (append '("digraph org_dependencies {")
                    '("  size=\"4,4!\";")
                    (-map (-partial #'s-prepend "  ") edges-dot)
                    '("}")))))

;;; Commands
;;;###autoload
(defun org-dpnds-agenda-dependencies (&optional transitive id-or-pom)
  (interactive "P")
  (setq id-or-pom (org-dpnds--pomoi-to-id id-or-pom 'create))
  (unless id-or-pom
    (error "id-or-pom must be an integer, marker, string or nil"))
  (org-dpnds-update-db-from-files (org-dpnds--get-depend-files) org-dpnds-db)
  (with-current-buffer (find-file-noselect (car (org-id-find id-or-pom)))
    (goto-char (cdr (org-id-find id-or-pom)))
    (let* ((dependencies (org-dpnds-get-dependencies
                          id-or-pom org-dpnds-db transitive))
           (org-agenda-overriding-header
            (format (if transitive
                        "Direct and transitive dependencies of: `%s'"
                      "Direct dependencies of: `%s'")
                    (plist-get (cadr (org-element-at-point)) :title)))
           (org-agenda-cmp-user-defined #'org-dpnds-sorting-strategy)
           (org-agenda-sorting-strategy '(user-defined-down))
           (org-agenda-files (list (buffer-file-name)))
           (org-agenda-skip-function
            (lambda () (if (member (org-id-get (point)) dependencies)
                           nil
                         ;; return (point-max), when at eob
                         (or (outline-next-heading) (point-max))))))
      (org-tags-view nil "{.*}"))))

;;;###autoload
(defun org-dpnds-capture-dependency (&optional pomoi capture-keys)
  (interactive)
  (let* ((from (org-dpnds--pomoi-to-id-check "pomoi" pomoi 'create))
         (add-dependency-at-point
          (lambda ()
            (message "in-hook:\n  buffer: %S\n  point: %S" (current-buffer) (point))
            (unless (eq (car (org-element-at-point)) 'headline)
              (outline-back-to-heading 'invisible-ok))
            (org-dpnds-add-dependency from (point)))))
    (org-dpnds-update-db-from-files (org-dpnds--get-depend-files) org-dpnds-db)
    (org-dpnds--capture-add-oneshot-hook add-dependency-at-point)
    (org-capture nil capture-keys)))

;;;###autoload
(defun org-dpnds-add-dependency (&optional from to)
  (interactive "P")
  (setq to (if (called-interactively-p 'any)
               (org-dpnds--get-id-with-outline-path-completion
                org-dpnds-files)
             (org-dpnds--pomoi-to-id-check "to" to 'create)))
  (setq from (if (eq from '(4))
                 (org-dpnds--get-id-with-outline-path-completion
                  org-dpnds-files)
               (org-dpnds--pomoi-to-id-check "from" from 'create)))
  (org-dpnds-update-db-from-files
   (org-dpnds--get-depend-files) org-dpnds-db)
  (org-dpnds--add-dependency to (org-id-find from 'as-marker)))

(declare-function image-transform-fit-to-height 'image-mode)
(declare-function image-transform-fit-to-width 'image-mode)
;;;###autoload
(defun org-dpnds-show-dependency-graph (&optional buffer)
  (interactive "bBuffer: ")
  (org-dpnds-update-db-from-files (org-dpnds--get-depend-files) org-dpnds-db)
  (let* ((ids (with-current-buffer (or buffer (current-buffer))
                (org-map-entries (lambda () (org-entry-get (point) "ID")))))
         (db (org-dpnds-update-db (buffer-file-name) org-dpnds-db))
         (graph (org-dpnds-graphs ids db))
         (dot (org-dpnds-graph-to-dot graph))
         (dot-file (with-temp-buffer
                     (insert dot)
                     (write-file (concat (make-temp-name "/tmp/org-dpnds-dot-") ".dot"))
                     (buffer-file-name)))
         (out-file (make-temp-file "/tmp/org-dpnds-dot-" nil ".png"))
         (ret-value (start-process
                     "dot" "*dot*" "/usr/bin/dot"
                     "-Tpng" (format "-o%s" out-file) dot-file)))
    (sit-for 5)
    (pop-to-buffer (find-file-noselect out-file))
    (image-transform-fit-to-height)
    (image-transform-fit-to-width)))

;;; test stuff
(defmacro org-dpnds-ignore-body (&rest body)
  nil)

(org-dpnds-ignore-body
 (setq org-dpnds-files
       (cons `((,(concat (file-name-directory (buffer-file-name)) "../test.org")) :maxlevel . 4)
             org-dpnds-files))
 )

(provide 'org-dpnds)
;;; org-dpnds.el ends here
